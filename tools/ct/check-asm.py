#!/usr/bin/env python3
"""Reads a target's disassembly of named functions and says whether a secret reaches a
conditional branch, a memory address or a division.

    check-asm.py <arch> <object> <spec> ...      spec:  function:secret-params

`arch` is x86_64, aarch64, wasm or xtensa. `secret-params` is a comma list of parameter
positions (0-based) holding secrets, or `*` for all; `@n` marks parameter n as a public
pointer to secret memory, so what is loaded through it is secret and the pointer isn't. A
function's parameters are in the target's registers (or Wasm locals) as its ABI has them.
Exits 1 and names the instruction when a secret gets there, so a fixture written to leak
fails: tools/test-ct.sh checks that too, and that is what keeps this honest.

This is a forward dataflow over registers and stack slots, iterated to a fixed point over
the function's jumps. It's conservative: whatever an instruction writes is secret if
anything it reads is. A call to anything but the listed helpers is a failure, because what it
does isn't known. Loads through a public pointer are public unless `@` says otherwise.
"""
import re
import subprocess
import sys

OBJDUMP = "llvm-objdump"


def disassemble(path, name, extra=()):
    text = subprocess.run(
        [OBJDUMP, "-d", "--no-show-raw-insn", "--disassemble-symbols=" + name, *extra, path],
        capture_output=True, text=True, check=True).stdout
    lines = []
    active = False
    for line in text.splitlines():
        if re.match(r"^[0-9a-f]+ <.*>:$", line):
            active = line.endswith(f"<{name}>:")
            continue
        if active and line.strip():
            m = re.match(r"^\s*([0-9a-f]+):\s*(.*)$", line)
            if m:
                # AArch64 uses # for immediates, including stack offsets; only
                # a whitespace-delimited # comment is an x86 disassembly comment.
                instruction = m.group(2).split("//")[0]
                instruction = re.sub(r"\s+#\s+.*$", "", instruction).strip()
                lines.append((int(m.group(1), 16), instruction))
    if not lines:
        raise SystemExit(f"{name}: no such function in {path}")
    return lines


class Violation(Exception):
    pass


def fixpoint(lines, start, step, successors):
    """Forward taint: `step` returns the state after an instruction, raising on a violation."""
    index = {address: i for i, (address, _) in enumerate(lines)}
    states = {0: start}
    work = [0]
    guard = 0
    while work:
        guard += 1
        if guard > 200000:
            raise SystemExit("no fixed point")
        i = work.pop()
        address, text = lines[i]
        out = step(states[i], text, address)
        for s in successors(text, i, index):
            if s >= len(lines):
                continue
            old = states.get(s)
            new = out if old is None else (old | out)
            if new != old:
                states[s] = new
                work.append(s)


# --- x86-64 (AT&T syntax) --------------------------------------------------------------
X86_ARGS = ["rdi", "rsi", "rdx", "rcx", "r8", "r9"]
X86_ALIAS = {}
for full, names in {
    "rax": "eax ax al ah", "rbx": "ebx bx bl bh", "rcx": "ecx cx cl ch", "rdx": "edx dx dl dh",
    "rsi": "esi si sil", "rdi": "edi di dil", "rbp": "ebp bp bpl", "rsp": "esp sp spl",
}.items():
    for n in names.split():
        X86_ALIAS[n] = full
for n in range(8, 16):
    for s in ["d", "w", "b"]:
        X86_ALIAS[f"r{n}{s}"] = f"r{n}"


def x86_reg(name):
    name = name.lstrip("%")
    if re.match(r"[xyz]mm\d+", name):
        return "v" + re.sub(r"\D", "", name)
    return X86_ALIAS.get(name, name)


def x86_split(ops):
    parts, depth, cur = [], 0, ""
    for c in ops:
        if c == "(":
            depth += 1
        if c == ")":
            depth -= 1
        if c == "," and depth == 0:
            parts.append(cur.strip())
            cur = ""
        else:
            cur += c
    if cur.strip():
        parts.append(cur.strip())
    return parts


X86_FLAGLESS = re.compile(r"^(mov|lea|cmov|set|vmov|vpxor|pxor|movz|movs|bswap|not|push|pop|nop|cdq|cqo|cltq|cwt|ret|jmp|call|xchg|rorx|rolx|shlx|shrx|sarx|andn|pand|por|padd|psub|pshuf|punpck|psll|psrl|psra|vp|movdq|movap|movup|movd|movq|ud2|endbr)")
X86_READWRITE = re.compile(r"^(add|adc|sub|sbb|and|or|xor|imul|shl|sal|shr|sar|rol|ror|neg|not|inc|dec|pand|por|pxor|pandn|padd|psub|psll|psrl|psra|pmul|punpck|pshufb|bswap|shld|shrd|cmov|aes|pclmul|andn|xchg)")


def check_x86(lines, secret, pointers):
    start = frozenset(X86_ARGS[i] for i in secret) | frozenset(["ptr:" + X86_ARGS[i] for i in pointers])

    def mem_parts(op):
        m = re.match(r"^(-?(?:0x)?[0-9a-f]*)\((%\w+)?(?:,(%\w+)(?:,\d+)?)?\)$", op)
        return m

    def step(state, text, address):
        state = set(state)
        parts = text.split(None, 1)
        op = parts[0]
        if op in ("lock", "rep", "notrack", "data16", "cs") and len(parts) > 1:
            parts = parts[1].split(None, 1)
            op = parts[0]
        ops = x86_split(parts[1]) if len(parts) > 1 else []
        tainted = lambda r: x86_reg(r) in state

        def read(o):
            if o.startswith("%"):
                return tainted(o)
            if o.startswith("$"):
                return False
            m = mem_parts(o)
            if m:
                base, idx = m.group(2), m.group(3)
                stack = base and x86_reg(base) in ("rsp", "rbp")
                if stack and not idx:
                    return ("slot:" + o) in state
                if (base and tainted(base)) or (idx and tainted(idx)):
                    if not op.startswith("lea"):
                        raise Violation(f"secret address: {text}")
                    return True
                if (base and "ptr:" + x86_reg(base) in state) or (idx and "ptr:" + x86_reg(idx) in state):
                    return True  # read through a pointer to secrets
                return "memory" in state and False
            return False

        def write(o, value):
            if o.startswith("%"):
                r = x86_reg(o)
                if value:
                    state.add(r)
                else:
                    state.discard(r)
                state.discard("ptr:" + r)
            else:
                m = mem_parts(o)
                if m:
                    base, idx = m.group(2), m.group(3)
                    if base and tainted(base) or idx and tainted(idx):
                        raise Violation(f"secret address: {text}")
                    if base and x86_reg(base) in ("rsp", "rbp") and not idx:
                        if value:
                            state.add("slot:" + o)
                        else:
                            state.discard("slot:" + o)

        if op.startswith("j") and op not in ("jmp", "jmpq"):
            if "flags" in state:
                raise Violation(f"secret branch: {text}")
            return frozenset(state)
        if op.startswith(("jmp",)):
            if ops and (ops[0].startswith("*")):
                raise Violation(f"indirect jump: {text}")
            return frozenset(state)
        if op.startswith("call"):
            target = ops[0] if ops else ""
            raise Violation(f"call: {text}")
        if op.startswith(("ret", "nop", "endbr", "ud2", "int3", "hlt")) or op == "":
            return frozenset(state)
        if re.match(r"^(i?div)[bwlq]?$", op):
            if any(read(o) for o in ops) or "rax" in state or "rdx" in state:
                raise Violation(f"secret division: {text}")
        if op.startswith("push"):
            if tainted(ops[0]):
                state.add("pushed")
            return frozenset(state)
        if op.startswith("pop"):
            write(ops[0], "pushed" in state)
            return frozenset(state)
        if op.startswith(("cmp", "test", "vptest", "ptest", "bt", "ucomis", "comis")):
            if any(read(o) for o in ops):
                state.add("flags")
            else:
                state.discard("flags")
            return frozenset(state)
        if op.startswith("lea"):
            value = read(ops[0])
            pointer_input = ops[0] and mem_parts(ops[0]) and mem_parts(ops[0]).group(2) and \
                "ptr:" + x86_reg(mem_parts(ops[0]).group(2)) in state
            write(ops[1], value and not pointer_input)
            if pointer_input:
                state.add("ptr:" + x86_reg(ops[1]))
            return frozenset(state)
        # A zeroing idiom forgets what it wrote over.
        if (op.startswith(("xor", "pxor", "vpxor", "sub", "xorp")) and len(ops) >= 2 and
                x86_reg(ops[0]) == x86_reg(ops[1]) and ops[0].startswith("%")):
            write(ops[-1], False)
            state.discard("flags")
            return frozenset(state)
        if op.startswith("mov") and len(ops) == 2 and ops[0].startswith("%") and ops[1].startswith("%") and \
                "ptr:" + x86_reg(ops[0]) in state:
            write(ops[1], False)
            state.add("ptr:" + x86_reg(ops[1]))
            return frozenset(state)
        inputs = any(read(o) for o in ops[:-1]) if ops else False
        # Three-operand IMUL overwrites its destination; unlike the two-operand
        # form, it does not read the destination's previous value.
        if ops and X86_READWRITE.match(op) and not (op.startswith("imul") and len(ops) == 3):
            inputs = inputs or read(ops[-1])
        if op.startswith(("mul", "imul")) and len(ops) == 1:
            inputs = read(ops[0]) or "rax" in state
            write("%rax", inputs)
            write("%rdx", inputs)
            if inputs:
                state.add("flags")
            return frozenset(state)
        if op.startswith(("cmov", "adc", "sbb", "set", "rcl", "rcr")) and "flags" in state:
            inputs = True
        if op in ("cltq", "cqto", "cltd", "cqo", "cdq", "cdqe", "cwtl"):
            inputs = "rax" in state
            if inputs:
                state.add("rdx")
            return frozenset(state)
        if ops:
            write(ops[-1], inputs)
        if not X86_FLAGLESS.match(op):
            if inputs:
                state.add("flags")
            else:
                state.discard("flags")
        return frozenset(state)

    def successors(text, i, index):
        parts = text.split()
        op = parts[0]
        out = []
        if op.startswith("ret") or op == "ud2" or op == "hlt":
            return out
        if op.startswith("j") and len(parts) > 1:
            m = re.match(r"^(?:0x)?([0-9a-f]+)", parts[1])
            if m and int(m.group(1), 16) in index:
                out.append(index[int(m.group(1), 16)])
            if op.startswith("jmp"):
                return out
        out.append(i + 1)
        return out

    fixpoint(lines, start, step, successors)


# --- AArch64 -----------------------------------------------------------------------------
def a64_reg(name):
    name = name.strip().split(".")[0].lstrip("#")
    m = re.match(r"^[wx](\d+)$", name)
    if m:
        return "x" + m.group(1)
    m = re.match(r"^[bhsdqv](\d+)$", name)
    if m:
        return "v" + m.group(1)
    return name


A64_FLAGS = re.compile(r"^(adds|subs|ands|bics|cmp|cmn|tst|ccmp|ccmn|adcs|sbcs|fcmp|negs)")
A64_BRANCH_REG = re.compile(r"^(cbz|cbnz|tbz|tbnz)$")


def check_aarch64(lines, secret, pointers):
    start = frozenset(f"x{i}" for i in secret) | frozenset(f"ptr:x{i}" for i in pointers)

    def split(ops):
        parts, depth, cur = [], 0, ""
        for c in ops:
            if c in "[{":
                depth += 1
            if c in "]}":
                depth -= 1
            if c == "," and depth == 0:
                parts.append(cur.strip())
                cur = ""
            else:
                cur += c
        if cur.strip():
            parts.append(cur.strip())
        return parts

    def stack_bytes(memory, register, op, index=0):
        match = re.fullmatch(r"\[(sp|x29)(?:,\s*#(-?(?:0x[0-9a-f]+|[0-9]+)))?\]!?", memory)
        if not match:
            return None
        offset = int(match.group(2), 0) if match.group(2) else 0
        kind = register.strip().lower()[0]
        size = 16 if kind == "q" else 8 if kind in ("x", "d") else 4 if kind in ("w", "s") else 2 if kind == "h" else 1
        if op.startswith(("ldrb", "ldrsb", "ldurb", "ldursb", "strb", "sturb")):
            size = 1
        elif op.startswith(("ldrh", "ldrsh", "ldurh", "ldursh", "strh", "sturh")):
            size = 2
        elif op.startswith(("ldrsw", "ldursw")):
            size = 4
        offset += index * size
        return [f"slot:{match.group(1)}:{offset + i}" for i in range(size)]

    def step(state, text, address):
        state = set(state)
        parts = text.split(None, 1)
        op = parts[0]
        ops = split(parts[1]) if len(parts) > 1 else []
        regs = lambda o: [a64_reg(r) for r in re.findall(r"\b[wxvbhsdq]\d+(?:\.\w+)?\b|\bsp\b", o)]
        t = lambda o: any(r in state for r in regs(o))
        if op.startswith("b.") or A64_BRANCH_REG.match(op):
            if op.startswith("b."):
                if "flags" in state:
                    raise Violation(f"secret branch: {text}")
            elif t(ops[0]):
                raise Violation(f"secret branch: {text}")
            return frozenset(state)
        if op in ("b", "ret", "nop", "brk", "hint", "bti", "paciasp", "autiasp", "udf", "dmb"):
            return frozenset(state)
        if op in ("bl", "blr", "br"):
            raise Violation(f"call: {text}")
        if op in ("sdiv", "udiv") and any(t(o) for o in ops[1:]):
            raise Violation(f"secret division: {text}")
        if op.startswith(("ldr", "ldur", "ldp", "ldrb", "ldrh", "ldrs", "ldx", "ldar", "ld1")):
            memory = next(o for o in ops if "[" in o)
            inner = regs(memory)
            if any(r in state for r in inner):
                raise Violation(f"secret address: {text}")
            dests = ops[:ops.index(memory)]
            for i, d in enumerate(dests):
                r = a64_reg(d)
                slots = stack_bytes(memory, d, op, i)
                value = any(slot in state for slot in slots) if slots is not None else any(
                    "ptr:" + reg in state for reg in inner
                )
                (state.add if value else state.discard)(r)
                state.discard("ptr:" + r)
            if "!" in memory or (len(ops) > len(dests) + 1):
                pass
            return frozenset(state)
        if op.startswith(("str", "stur", "stp", "stx", "stlr", "st1")):
            memory = next(o for o in ops if "[" in o)
            inner = regs(memory)
            if any(r in state for r in inner):
                raise Violation(f"secret address: {text}")
            sources = ops[:ops.index(memory)]
            for i, source in enumerate(sources):
                slots = stack_bytes(memory, source, op, i)
                if slots is not None:
                    for slot in slots:
                        (state.add if t(source) else state.discard)(slot)
            return frozenset(state)
        if op in ("cmp", "cmn", "tst", "fcmp", "ccmp", "ccmn"):
            value = any(t(o) for o in ops)
            if op.startswith("cc") and "flags" in state:
                value = True
            (state.add if value else state.discard)("flags")
            return frozenset(state)
        if not ops:
            return frozenset(state)
        dest = a64_reg(ops[0])
        value = any(t(o) for o in ops[1:])
        if op.startswith(("csel", "csinc", "csinv", "csneg", "cset", "csetm", "adc", "sbc", "cinc", "cinv", "cneg")) and "flags" in state:
            value = True
        # Vector instructions that keep part of what they write.
        if op in ("ins", "mov", "aese", "aesd", "aesmc", "aesimc", "bsl", "bit", "bif", "sli", "sri") and "." in ops[0]:
            value = value or dest in state
        # What a pointer to secrets becomes through moves and offsets stays one.
        src = a64_reg(ops[1]) if len(ops) > 1 else ""
        if op in ("mov", "add", "sub") and "ptr:" + src in state and dest != "sp":
            state.add("ptr:" + dest)
            state.discard(dest)
            return frozenset(state)
        # A zeroing idiom.
        if op == "eor" and len(ops) == 3 and ops[1] == ops[2]:
            value = False
        (state.add if value else state.discard)(dest)
        state.discard("ptr:" + dest)
        if A64_FLAGS.match(op):
            (state.add if value else state.discard)("flags")
        return frozenset(state)

    def successors(text, i, index):
        parts = text.split()
        op = parts[0]
        if op in ("ret", "udf", "brk"):
            return []
        out = []
        if op == "b" or op.startswith("b.") or A64_BRANCH_REG.match(op):
            m = re.search(r"0x([0-9a-f]+)\s*(<|$)", text)
            if m is None:
                m = re.search(r"([0-9a-f]+) <", text)
            if m and int(m.group(1), 16) in index:
                out.append(index[int(m.group(1), 16)])
            if op == "b":
                return out
        out.append(i + 1)
        return out

    fixpoint(lines, start, step, successors)


# --- Xtensa (windowed ABI: arguments in a2 up) ----------------------------------------------
XT_BRANCH = re.compile(r"^(beq|bne|bge|blt|bgeu|bltu|bany|bnone|ball|bnall|bbc|bbs|beqz|bnez|bgez|bltz|beqi|bnei|bgei|blti|bgeui|bltui|bbci|bbsi)(\.n)?$")
XT_COND_MOVE = re.compile(r"^(moveqz|movnez|movltz|movgez)")


def check_xtensa(lines, secret, pointers):
    # A u64 takes an aligned pair of registers, so positions don't map one to one: any secret
    # parameter makes all the argument registers secret, and only pointer lists are exact.
    # (A pointer parameter is an `int`, so also a pair: the address is the low one.)
    start = frozenset(f"ptr:a{2 + 2 * i}" for i in pointers)
    if secret and not pointers:
        start = start | frozenset(f"a{i}" for i in range(2, 8))
    elif secret:
        # Past the pointers' pairs, a u32 parameter lands at the next register, or on the stack
        # if there's none left, and then this checker can't see it: refuse rather than pass it.
        for i in secret:
            at = 2 + 2 * i
            if at > 7:
                raise SystemExit("a secret past the argument registers isn't read here")
            start = start | frozenset([f"a{at}"])

    def step(state, text, address):
        state = set(state)
        parts = text.split(None, 1)
        op = parts[0]
        ops = [o.strip() for o in parts[1].split(",")] if len(parts) > 1 else []
        t = lambda o: o in state
        if XT_BRANCH.match(op):
            if any(t(o) for o in ops[:-1]):
                raise Violation(f"secret branch: {text}")
            return frozenset(state)
        if op in ("j", "j.n", "retw", "retw.n", "ret", "ret.n", "nop", "nop.n", "memw", "entry", "ill", "ill.n"):
            return frozenset(state)
        if op.startswith(("call", "callx", "jx")):
            raise Violation(f"call: {text}")
        if op in ("quos", "quou", "rems", "remu") and any(t(o) for o in ops[1:]):
            raise Violation(f"secret division: {text}")
        m = re.match(r"^(l8ui|l16ui|l16si|l32i|l32i\.n)$", op)
        if m:
            dest, base, offset = ops[0], ops[1], ops[2] if len(ops) > 2 else "0"
            if t(base):
                raise Violation(f"secret address: {text}")
            value = False
            if base == "a1":
                value = f"slot:{offset}" in state
            elif "ptr:" + base in state:
                value = True
            (state.add if value else state.discard)(dest)
            state.discard("ptr:" + dest)
            return frozenset(state)
        m = re.match(r"^(s8i|s16i|s32i|s32i\.n)$", op)
        if m:
            source, base, offset = ops[0], ops[1], ops[2] if len(ops) > 2 else "0"
            if t(base):
                raise Violation(f"secret address: {text}")
            if base == "a1":
                (state.add if t(source) else state.discard)(f"slot:{offset}")
            return frozenset(state)
        if op == "l32r":
            state.discard(ops[0])
            return frozenset(state)
        if not ops:
            return frozenset(state)
        dest = ops[0]
        value = any(t(o) for o in ops[1:])
        if XT_COND_MOVE.match(op):
            value = value or t(dest)
        if op in ("xor",) and ops[1] == ops[2]:
            value = False
        if op in ("addi", "addi.n", "mov", "mov.n", "or", "add", "add.n", "addmi", "addx2", "addx4", "addx8") and \
                any("ptr:" + o in state for o in ops[1:]):
            state.add("ptr:" + dest)
            state.discard(dest)
            return frozenset(state)
        (state.add if value else state.discard)(dest)
        state.discard("ptr:" + dest)
        return frozenset(state)

    def successors(text, i, index):
        parts = text.split(None, 1)
        op = parts[0]
        if op in ("retw", "retw.n", "ret", "ret.n", "ill", "ill.n"):
            return []
        out = []
        if XT_BRANCH.match(op) or op in ("j", "j.n"):
            m = re.search(r"(?:0x)?([0-9a-f]+)(?:\s*<[^>]*>)?\s*$", parts[1])
            if m and int(m.group(1), 16) in index:
                out.append(index[int(m.group(1), 16)])
            if op in ("j", "j.n"):
                return out
        out.append(i + 1)
        return out

    fixpoint(lines, start, step, successors)


# --- Wasm ----------------------------------------------------------------------------------
WASM_BINARY = re.compile(r"^(i32|i64|f32|f64|v128|i8x16|i16x8|i32x4|i64x2|f32x4|f64x2)\.(add|sub|mul|and|or|xor|shl|shr_s|shr_u|rotl|rotr|eq|ne|lt_s|lt_u|gt_s|gt_u|le_s|le_u|ge_s|ge_u|div|min|max|lt|gt|le|ge|copysign|andnot|add_sat_s|add_sat_u|sub_sat_s|sub_sat_u)$")
WASM_UNARY = re.compile(r"^(i32|i64|f32|f64|v128|i8x16|i16x8|i32x4|i64x2|f32x4|f64x2)\.(eqz|clz|ctz|popcnt|wrap_i64|extend\w*|trunc\w*|convert\w*|reinterpret\w*|promote\w*|demote\w*|not|neg|abs|sqrt|splat|any_true|all_true|bitmask|extract_lane\w*)\b")


def check_wasm(lines, secret, pointers):
    # Function parameters are locals. The stack's shape follows from each instruction, and the
    # lines are visited in order several times to carry what locals pick up around loops.
    # Each pass starts at the function's entry; a loop's head joins what its back edges brought in
    # the pass before, and a block's end what branches out of it did, until nothing changes.
    heads = {}
    for _ in range(64):
        before = {k: (set(v[0]), set(v[1])) for k, v in heads.items()}
        locals_tainted = set(secret)
        pointer_locals = set(pointers)
        stack = []
        control = []
        unreachable = False

        def branch_to(depth):
            if depth >= len(control):
                return
            entry = control[-1 - depth]
            if entry["kind"] == "loop":
                head = heads.setdefault(entry["at"], (set(), set()))
                head[0].update(locals_tainted)
                head[1].update(pointer_locals)
                return
            entry["exit_tainted"].update(locals_tainted)
            entry["exit_pointer"].update(pointer_locals)
            if entry["results"] and stack:
                entry["secret"] = entry["secret"] or stack[-1][0]
                entry["pointer"] = entry["pointer"] or stack[-1][1]

        for at, (address, text) in enumerate(lines):
            parts = text.split()
            if not parts or parts[0] == "local":
                continue
            op = parts[0]
            if op in ("block", "loop", "if"):
                if op == "if" and not unreachable:
                    value = stack.pop() if stack else (False, False)
                    if value[0]:
                        raise Violation(f"secret branch: {text}")
                if op == "loop" and at in heads:
                    locals_tainted |= heads[at][0]
                    pointer_locals |= heads[at][1]
                control.append({"kind": op, "at": at, "height": len(stack),
                                "results": len(parts) > 1 and parts[1] != "#",
                                "secret": False, "pointer": False, "dead": unreachable,
                                "start_tainted": set(locals_tainted), "start_pointer": set(pointer_locals),
                                "exit_tainted": set(), "exit_pointer": set(), "else": False})
                continue
            if op in ("else", "end"):
                entry = control.pop() if control else None
                if entry is None:
                    continue  # the function's own end
                if not unreachable:
                    entry["exit_tainted"].update(locals_tainted)
                    entry["exit_pointer"].update(pointer_locals)
                    if entry["results"] and stack:
                        entry["secret"] = entry["secret"] or stack[-1][0]
                        entry["pointer"] = entry["pointer"] or stack[-1][1]
                del stack[entry["height"]:]
                if op == "else":
                    entry["else"] = True
                    control.append(entry)
                    locals_tainted = set(entry["start_tainted"])
                    pointer_locals = set(entry["start_pointer"])
                    unreachable = entry["dead"]
                else:
                    if entry["kind"] == "if" and not entry["else"]:
                        entry["exit_tainted"].update(entry["start_tainted"])
                        entry["exit_pointer"].update(entry["start_pointer"])
                    locals_tainted = set(entry["exit_tainted"])
                    pointer_locals = set(entry["exit_pointer"])
                    if entry["results"]:
                        stack.append((entry["secret"], entry["pointer"]))
                    unreachable = entry["dead"]
                continue
            if unreachable:
                continue
            if op in ("nop", "drop") or op.startswith("end_"):
                if op == "drop" and stack:
                    stack.pop()
                continue
            if op in ("return", "unreachable"):
                unreachable = True
                continue
            if op == "br":
                branch_to(int(parts[1]))
                unreachable = True
                continue
            if op in ("br_if", "br_table"):
                value = stack.pop() if stack else (False, False)
                if value[0]:
                    raise Violation(f"secret branch: {text}")
                if op == "br_if":
                    branch_to(int(parts[1]))
                else:
                    for depth in range(len(control)):
                        branch_to(depth)
                    unreachable = True
                continue
            if op == "local.get":
                n = int(parts[1])
                stack.append((n in locals_tainted, n in pointer_locals))
            elif op in ("local.set", "local.tee"):
                n = int(parts[1])
                value = stack[-1] if stack else (False, False)
                if op == "local.set" and stack:
                    stack.pop()
                (locals_tainted.add if value[0] else locals_tainted.discard)(n)
                (pointer_locals.add if value[1] else pointer_locals.discard)(n)
            elif op == "global.get" or re.match(r"^(i32|i64|f32|f64)\.const$", op) or op == "v128.const":
                stack.append((False, False))
            elif op == "global.set":
                if stack:
                    stack.pop()
            elif re.match(r"^(i32|i64|f32|f64|v128)\.load", op):
                address_value = stack.pop() if stack else (False, False)
                if address_value[0]:
                    raise Violation(f"secret address: {text}")
                stack.append((address_value[1], False))
            elif re.match(r"^(i32|i64|f32|f64|v128)\.store", op):
                _value = stack.pop() if stack else (False, False)
                address_value = stack.pop() if stack else (False, False)
                if address_value[0]:
                    raise Violation(f"secret address: {text}")
            elif op in ("select", "f32.select"):
                # (llvm-objdump prints the untyped select as f32.select.) It's data in the
                # language, but what an engine makes of it is its own business.
                c = stack.pop() if stack else (False, False)
                if c[0]:
                    raise Violation(f"secret select, which an engine may branch on: {text}")
                b = stack.pop() if stack else (False, False)
                a = stack.pop() if stack else (False, False)
                stack.append((a[0] or b[0] or c[0], a[1] or b[1]))
            elif op in ("call", "call_indirect"):
                raise Violation(f"call: {text}")
            elif re.match(r"^(i32|i64)\.(div|rem)_", op):
                b = stack.pop() if stack else (False, False)
                a = stack.pop() if stack else (False, False)
                if a[0] or b[0]:
                    raise Violation(f"secret division: {text}")
                stack.append((False, False))
            elif WASM_BINARY.match(op) or "shuffle" in op or ".replace_lane" in op or "bitselect" in op:
                b = stack.pop() if stack else (False, False)
                a = stack.pop() if stack else (False, False)
                c = (False, False)
                if "bitselect" in op and stack:
                    c = stack.pop()
                stack.append((a[0] or b[0] or c[0], (a[1] or b[1]) and not (a[0] or b[0])))
            elif WASM_UNARY.match(op):
                a = stack.pop() if stack else (False, False)
                # A pointer stays one through a change of width (an int's address is an i64).
                stack.append((a[0], a[1] and ("wrap" in op or "extend" in op)))
            else:
                raise Violation(f"instruction this checker doesn't know: {text}")
        if {k: (set(v[0]), set(v[1])) for k, v in heads.items()} == before:
            return
    raise SystemExit("no fixed point")


CHECKERS = {"x86_64": check_x86, "aarch64": check_aarch64, "xtensa": check_xtensa, "wasm": check_wasm}


def parse_spec(spec, count_hint=8):
    name, _, roles = spec.partition(":")
    secret, pointers = [], []
    if roles == "*":
        secret = list(range(count_hint))
    elif roles:
        for r in roles.split(","):
            if r.startswith("@"):
                pointers.append(int(r[1:]))
            else:
                secret.append(int(r))
    return name, secret, pointers


def main():
    arch, path, *specs = sys.argv[1:]
    failed = 0
    for spec in specs:
        name, secret, pointers = parse_spec(spec)
        lines = disassemble(path, name, ["--mcpu=esp32"] if arch == "xtensa" else [])
        # What the disassembler can't read could be anything: a pass over it would mean nothing.
        unread = [text for _, text in lines if "unknown" in text]
        if unread:
            print(f"LEAK {arch} {name}: the disassembler can't read: {unread[0]}")
            failed = 1
            continue
        try:
            CHECKERS[arch](lines, secret, pointers)
            print(f"ok   {arch} {name} ({len(lines)} instructions)")
        except Violation as violation:
            print(f"LEAK {arch} {name}: {violation}")
            failed = 1
    sys.exit(failed)


if __name__ == "__main__":
    main()
