#!/usr/bin/env python3
"""Reads a target's disassembly of named functions and says whether a secret reaches a
conditional branch, a memory address or a division.

    check-asm.py [--follow-calls] [--residue] <arch> <object> <spec> ...      spec:  function:secret-params

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


XT_LITERALS = {}


def xtensa_literal_symbols(path):
    """(literal section, offset) -> the symbol an R_XTENSA_32 relocation puts there: the address a `l32r` loads."""
    if path not in XT_LITERALS:
        table = {}
        section = None
        for line in subprocess.run([OBJDUMP, "-r", path], capture_output=True, text=True, check=True).stdout.splitlines():
            m = re.match(r"^RELOCATION RECORDS FOR \[(.*)\]:", line)
            if m:
                section = m.group(1)
                continue
            m = re.match(r"^([0-9a-f]+)\s+R_XTENSA_32\s+(\S+)$", line)
            if m and section:
                table[(section, int(m.group(1), 16))] = m.group(2)
        XT_LITERALS[path] = table
    return XT_LITERALS[path]


def disassemble(path, name, extra=()):
    text = subprocess.run(
        [OBJDUMP, "-d", "--no-show-raw-insn", "--disassemble-symbols=" + name, *extra,
         *(["-r"] if "--mcpu=esp32" in extra else []), path],
        capture_output=True, text=True, check=True).stdout
    lines = []
    active = False
    for line in text.splitlines():
        if re.match(r"^[0-9a-f]+ <.*>:$", line):
            active = line.endswith(f"<{name}>:")
            continue
        if active and line.strip():
            relocation = re.match(r"^\s*[0-9a-f]+:\s+R_XTENSA_\w+\s+(\S+)$", line)
            if relocation:
                # A call in an unlinked Xtensa object names its callee by relocation, against the callee's section
                # (one function a section): put it where an x86 disassembly puts `<name>`.
                target = relocation.group(1)
                if lines and lines[-1][1].split()[0].startswith("call") and "<" not in lines[-1][1]:
                    target = target[len(".text."):] if target.startswith(".text.") else target
                    lines[-1] = (lines[-1][0], f"{lines[-1][1]} <{target}>")
                elif lines and lines[-1][1].split()[0] == "l32r":
                    # A literal's address: the symbol its own relocation names, in the next call if it is a callx.
                    literal = re.match(r"^(\.literal\.\S+?)(?:\+0x([0-9a-f]+))?$", target)
                    if literal:
                        symbol = xtensa_literal_symbols(path).get((literal.group(1), int(literal.group(2) or "0", 16)))
                        if symbol:
                            lines[-1] = (lines[-1][0], f"{lines[-1][1]} <{symbol}>")
                continue
            m = re.match(r"^\s*([0-9a-f]+):\s*(.*)$", line)
            if m:
                # AArch64 uses # for immediates, including stack offsets; only
                # a whitespace-delimited # comment is an x86 disassembly comment.
                instruction = m.group(2).split("//")[0]
                instruction = re.sub(r"\s+#\s+.*$", "", instruction).strip()
                lines.append((int(m.group(1), 16), instruction))
    for i in range(1, len(lines)):
        # `l32r aN, <literal> <sym>` straight before `callxK aN`: a call to sym (the long-call form).
        load = re.match(r"^l32r\s+(a\d+),\s*\S+\s+<([^>]+)>$", lines[i - 1][1])
        call = re.match(r"^callx(4|8|12)\s+(a\d+)$", lines[i][1])
        if load and call and load.group(1) == call.group(2):
            lines[i] = (lines[i][0], f"call{call.group(1)} 0x0 <{load.group(2)}>")
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
    return states


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


def callee_inputs(name):
    """The argument registers a function may read before writing them. In its straight-line start it is what
    that code reads first; from the first branch, call or jump on, every register not yet written counts as read."""
    written = set()
    read = set()
    for _, text in disassemble(FOLLOW["path"], name):
        parts = text.split(None, 1)
        op = parts[0]
        if op in ("rep", "lock", "notrack") and len(parts) > 1:
            parts = parts[1].split(None, 1)
            op = parts[0]
        ops = x86_split(parts[1]) if len(parts) > 1 else []
        if op.startswith(("j", "call", "ret")) or op.startswith("loop"):
            if op.startswith("ret"):
                return read
            return read | (set(X86_ARGS) - written)
        mentioned = [[x86_reg(r) for r in re.findall(r"%\w+", o)] for o in ops]
        zeroing = (op.startswith(("xor", "sub", "pxor")) and len(ops) == 2 and ops[0] == ops[1])
        string_op = op.startswith(("stos", "movs", "scas", "cmps", "lods"))
        for index, regs in enumerate(mentioned):
            is_destination = index == len(ops) - 1 and len(ops) >= 2
            if ops[index].startswith("%") and is_destination and not X86_READWRITE.match(op) and not op.startswith(("cmp", "test")):
                continue
            if zeroing:
                continue
            read |= {r for r in regs if r not in written}
        if string_op:
            used = ("rdi", "rcx", "rax") if op.startswith("stos") else ("rdi", "rcx", "rsi") if op.startswith("movs") else ("rdi", "rcx", "rax", "rsi")
            read |= {r for r in used if r not in written}
        if ops and ops[-1].startswith("%"):
            written.add(x86_reg(ops[-1]))
        if zeroing:
            written.add(x86_reg(ops[-1]))
    return read | (set(X86_ARGS) - written)


EXTENTS = {}


def stack_extent(name, seen=()):
    """How many bytes below its caller's stack pointer a function and what it calls can have written:
    the return address, everything that grows its stack (pushes, a frame, alignment), the red zone below
    that, and the deepest callee. Growth it can't evaluate is a Violation, not a guess."""
    if name in seen:
        raise Violation(f"call: recursion into {name}")
    if name in EXTENTS:
        return EXTENTS[name]
    lines = disassemble(FOLLOW["path"], name)
    growth = 8
    red_zone = 0
    deepest = 0
    for _, text in lines:
        parts = text.split(None, 1)
        op = parts[0]
        ops = x86_split(parts[1]) if len(parts) > 1 else []
        if op.startswith(("push",)):
            growth += 8
        elif ops and ops[-1] in ("%rsp", "%esp"):
            if op.startswith(("sub", "add")) and ops[0].startswith("$"):
                value = int(ops[0][1:], 0)
                growth += value if op.startswith("sub") else -value if value < 0 else 0
            elif op.startswith("and") and ops[0].startswith("$"):
                growth += 15
            elif op.startswith("lea") and (m := re.match(r"^(-?(?:0x)?[0-9a-f]+)\(%rsp\)$", ops[0])):
                growth += max(-int(m.group(1), 0), 0)
            elif op.startswith(("add", "lea")) or op.startswith("mov") and ops[0] == "%rbp":
                pass  # an epilogue: the stack gets shallower
            else:
                raise Violation(f"call: the stack growth of {name} can't be evaluated: {text}")
        for m in re.finditer(r"(-(?:0x)?[0-9a-f]+)\(%rsp\)", text):
            red_zone = max(red_zone, -int(m.group(1), 0))
        target = re.search(r"^(?:call\w*|jmp\w*)\s+(?:0x)?[0-9a-f]+ <([^>+]+)>$", text)
        if target and target.group(1) != name:
            deepest = max(deepest, stack_extent(target.group(1), seen + (name,)))
    EXTENTS[name] = growth + red_zone + deepest
    return EXTENTS[name]


# With --follow-calls, a call to a function defined in the same object (what a --fast build makes of
# every Abla call) is checked as a function of its own, on the arguments the caller passes, instead of
# failing. A call to anything not defined there, or a recursion, still fails.
FOLLOW = {"path": None, "stack": [], "done": {}, "residue": False, "followed": set()}


def follow_call(name, secret, pointers, text, check=None):
    FOLLOW["followed"].add(name)
    check = check or check_x86
    key = (check.__name__, name, tuple(secret), tuple(pointers))
    if key in FOLLOW["done"]:
        return FOLLOW["done"][key]
    if name in FOLLOW["stack"]:
        raise Violation(f"call: recursion into {name}: {text}")
    try:
        lines = disassemble(FOLLOW["path"], name)
    except SystemExit:
        raise Violation(f"call: {name} isn't defined in the object: {text}")
    unread = [t for _, t in lines if "unknown" in t]
    if unread:
        raise Violation(f"call: the disassembler can't read {name}: {unread[0]}")
    FOLLOW["stack"].append(name)
    try:
        returned = check(lines, secret, pointers)
    except Violation as violation:
        raise Violation(f"in {name}: {violation}")
    finally:
        FOLLOW["stack"].pop()
    FOLLOW["done"][key] = returned
    return returned


def x86_access_width(op, ops):
    """The bytes a plain integer move, compare or test touches in its memory operand; 0 if it isn't one of those (a
    vector move, a string operation, anything else), so that the access is never taken for a header word."""
    sizes = {"b": 1, "w": 2, "l": 4, "q": 8}
    widths = {}
    for names, size in ((("al", "bl", "cl", "dl", "sil", "dil", "bpl", "spl", "ah", "bh", "ch", "dh"), 1),
                        (("ax", "bx", "cx", "dx", "si", "di", "bp", "sp"), 2),
                        (("eax", "ebx", "ecx", "edx", "esi", "edi", "ebp", "esp"), 4)):
        for name in names:
            widths[name] = size
    def register_width(o):
        name = o.lstrip("%")
        if name in widths:
            return widths[name]
        if re.fullmatch(r"r(8|9|1[0-5])b", name):
            return 1
        if re.fullmatch(r"r(8|9|1[0-5])w", name):
            return 2
        if re.fullmatch(r"r(8|9|1[0-5])d", name):
            return 4
        if re.fullmatch(r"r[a-z0-9]+", name):
            return 8
        return 0
    m = re.fullmatch(r"(mov|cmp|test)([bwlq]?)", op)
    if m:
        if m.group(2):
            return sizes[m.group(2)]
        registers = [register_width(o) for o in ops if o.startswith("%")]
        return registers[0] if len(registers) == 1 else 0
    m = re.fullmatch(r"mov[zs]([bwl])[wlq]", op)
    if m:
        return sizes[m.group(1)]
    return 0


# Registers a function gets from its caller unchanged (SysV): until it writes one, what it pushes from it is the
# caller's value, as secret as the caller's own taint says.
X86_CALLEE_SAVED = ("rbx", "rbp", "r12", "r13", "r14", "r15")


def check_x86(lines, secret, pointers):
    index_of_lines = {address for address, _ in lines}
    returned = []
    header_args = FOLLOW.get("header_args", [])
    FOLLOW["header_args"] = []  # a followed callee has none
    start = (frozenset(X86_ARGS[i] for i in secret) | frozenset(["ptr:" + X86_ARGS[i] for i in pointers]) |
             frozenset(["rspd:0"]) | frozenset("hdrp:" + X86_ARGS[i] for i in header_args) |
             frozenset(f"entry:{r}" for r in X86_CALLEE_SAVED))

    def rsp_delta(state):
        """How far rsp is below its value at entry, as the tag says; "?" if it isn't one number."""
        deltas = [t.split(":")[1] for t in state if t.startswith("rspd:")]
        return deltas[0] if len(deltas) == 1 else "?"

    def move_rsp(state, change):
        before = rsp_delta(state)
        for tag in [t for t in state if t.startswith(("rspd:", "rspoff:"))]:
            state.discard(tag)
        state.add("rspd:" + (str(int(before) + change) if before != "?" and change is not None else "?"))

    def after_call(state, name, text):
        state = set(state)
        if name == "abla_platform_panic":
            # A panic (a division by zero, an index out of range) ends the program, so what it does isn't read.
            # It is reached only on a branch the checker has already required to be public, and no secret goes in.
            if "rdi" in state or "ptr:rdi" in state:  # its one argument, a message
                raise Violation(f"call: a panic is given a secret or a pointer to one: {text}")
            return frozenset(state)
        inputs = callee_inputs(name)
        secret_arguments = [i for i, r in enumerate(X86_ARGS) if r in state and r in inputs]
        pointer_arguments = [i for i, r in enumerate(X86_ARGS) if "ptr:" + r in state and r not in state and r in inputs]
        out = follow_call(name, secret_arguments, pointer_arguments, text)
        # The callee ran on exactly these arguments. What it returns in rax, rdx and the vector
        # registers is what its own analysis found; the other registers it may clobber are dead.
        for r in ["rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11"] + [f"v{n}" for n in range(16)]:
            state.discard(r)
            state.discard("ptr:" + r)
            for tag in [t for t in state if t.startswith(("rspoff:" + r + ":", "const:" + r + ":", "zero:" + r))]:
                state.discard(tag)
            if r in out:
                state.add(r)
            if "ptr:" + r in out:
                state.add("ptr:" + r)
        state.discard("flags")
        # Memory it was given may now hold secrets. Once the function has made an address in its own
        # frame (lea or mov from rsp), it may have been spilled, pushed or kept in a callee-saved
        # register, and the callee may have written through it: every slot read after a call is secret.
        if "frameaddr" in state:
            state.add("pushed")
        here = rsp_delta(state)
        for wipe in [t for t in out if t.startswith("wipe:")]:
            # A callee that wiped the stack below itself: its stack pointer is 8 below ours (the return address).
            _, low, high, *regs = wipe.split(":")
            if regs and any(r in state or "ptr:" + r in state for r in regs[0].split("+")):
                continue
            for tag in [t for t in state if t.startswith("dirty:")]:
                _, at_call, depth = tag.split(":")
                if here != "?" and at_call != "?":
                    if (-int(here) - 8 + int(low) <= -int(at_call) - int(depth) and
                            -int(here) - 8 + int(high) >= -int(at_call) - 8):
                        state.discard(tag)
        if FOLLOW["residue"] and (secret_arguments or pointer_arguments):
            # Whatever the callee wrote below our stack pointer may hold a secret; a wipe has to reach it.
            state.add(f"dirty:{rsp_delta(state)}:{stack_extent(name)}")
        return frozenset(state)

    texts_at = {address: text for address, text in lines}

    def trap_note(text):
        """A branch whose taken side is a ud2 is a runtime check (a type-tag require); say so, so the name of
        its function (hashed without -g) doesn't decide how the fast build's finding is classed."""
        m = re.match(r"^\S+\s+(?:0x)?([0-9a-f]+)", text)
        target = texts_at.get(int(m.group(1), 16), "") if m else ""
        return " (to trap)" if target.split()[:1] == ["ud2"] else ""

    def mem_parts(op):
        m = re.match(r"^(-?(?:0x)?[0-9a-f]*)\((%\w+)?(?:,(%\w+)(?:,\d+)?)?\)$", op)
        return m

    def mark_lost(state, op, ops):
        """A header-public pointer stays one only while its register is never written: any instruction that may write
        it (a bare register operand other than a mov/cmp/test/push source, or an implicit writer) or a call ends it. A
        merge keeps `lost`, since the states are joined by union."""
        if op.startswith(("call", "syscall")):
            for r in ["rax", "rcx", "rdx", "rsi", "rdi", "r8", "r9", "r10", "r11"]:
                state.add("lost:" + r)
            return
        if re.fullmatch(r"cmp[bwlq]?|test[bwlq]?|j\w+|push[wlq]?|nop\w*|endbr\w*|ret\w*", op):
            return
        if op.startswith(("mul", "imul", "div", "idiv", "cqo", "cltd", "cdq", "cltq", "cwt", "cbw", "xchg", "cmpxchg",
                          "xadd", "rep", "movs", "stos", "scas", "cmps", "lods", "cpuid", "rdtsc", "rdrand",
                          "rdseed", "sh", "sa", "ro", "rc", "pop")):
            for r in ["rax", "rcx", "rdx"]:
                state.add("lost:" + r)
        if op.startswith(("movs", "stos", "scas", "cmps", "lods", "cmpxchg", "cpuid")):
            # The string operations advance rdi and rsi; cpuid writes rbx.
            for r in ["rsi", "rdi", "rbx"]:
                state.add("lost:" + r)
        for i, o in enumerate(ops):
            if o.startswith("%"):
                if op.startswith("mov") and not op.startswith(("movs", "movz")) or op.startswith(("movz", "lea")):
                    if i != len(ops) - 1:
                        continue
                state.add("lost:" + x86_reg(o))

    def step(state, text, address):
        state = set(state)
        parts = text.split(None, 1)
        op = parts[0]
        repeated = op == "rep"
        if op in ("lock", "rep", "notrack", "data16", "cs") and len(parts) > 1:
            parts = parts[1].split(None, 1)
            op = parts[0]
        ops = x86_split(parts[1]) if len(parts) > 1 else []
        if header_args:
            mark_lost(state, op, ops)
        # Any instruction naming a register as its destination (AT&T: the last operand) may have changed it.
        if ops and ops[-1].startswith("%") and not op.startswith(("push", "cmp", "test")):
            state.discard("entry:" + x86_reg(ops[-1]))
        if op.startswith("push"):
            move_rsp(state, 8)
        elif op.startswith("pop"):
            move_rsp(state, -8)
        elif ops and ops[-1] in ("%rsp", "%esp") and not op.startswith(("cmp", "test")):
            if op.startswith(("sub", "add")) and ops[0].startswith("$"):
                move_rsp(state, int(ops[0][1:], 0) * (1 if op.startswith("sub") else -1))
            elif op.startswith("lea") and (m := re.match(r"^(-?(?:0x)?[0-9a-f]+)\(%rsp\)$", ops[0])):
                move_rsp(state, -int(m.group(1), 0))
            else:
                move_rsp(state, None)
        tainted = lambda r: x86_reg(r) in state

        def stack_slots(o):
            m = mem_parts(o)
            if not m or not m.group(2) or m.group(3):
                return None
            base = x86_reg(m.group(2))
            if base != "rsp" and (base != "rbp" or "stackbase:rbp" not in state):
                return None
            if "ptr:" + base in state:
                return None
            displacement = m.group(1)
            offset = int(displacement, 0) if displacement not in ("", "-") else 0
            # The memory width is the source width for extending loads.
            if re.match(r"^mov[zs]b", op):
                size = 1
            elif re.match(r"^mov[zs]w", op):
                size = 2
            elif re.match(r"^movs[lq]", op):
                size = 4
            elif op.endswith("b"):
                size = 1
            elif op.endswith("w"):
                size = 2
            elif op.endswith("l"):
                size = 4
            elif op.endswith("q"):
                size = 8
            elif op.startswith(("movdqu", "movdqa", "movups", "movaps")):
                size = 16
            else:
                # Unknown stack widths cannot safely discard any pointer bytes.
                size = 16
            return [f"{base}:{offset + i}" for i in range(size)]

        def stack_tagged(slots, prefix):
            if any(prefix + slot in state for slot in slots):
                return True
            base = slots[0].split(":", 1)[0]
            return any(item.startswith(prefix) and (
                "stack-moved" in state or not item.startswith(prefix + base + ":")
            ) for item in state)

        def read_pointer(o):
            if o.startswith("%"):
                return "ptr:" + x86_reg(o) in state
            slots = stack_slots(o)
            return slots is not None and ("pushed_ptr" in state or stack_tagged(slots, "ptrslot:"))

        def read(o):
            if o.startswith("%"):
                return tainted(o)
            if o.startswith("$"):
                return False
            m = mem_parts(o)
            if m:
                base, idx = m.group(2), m.group(3)
                if (base and tainted(base)) or (idx and tainted(idx)):
                    if not op.startswith("lea"):
                        raise Violation(f"secret address: {text}")
                    return True
                if (base and not idx and "hdrp:" + x86_reg(base) in state and
                        "lost:" + x86_reg(base) not in state and re.match(r"^-?(?:0x)?[0-9a-f]*$", m.group(1) or "")):
                    start = int(m.group(1), 0) if m.group(1) not in ("", "-") else 0
                    width = x86_access_width(op, ops)
                    if width and 0 <= start and start + width <= HEADER_BYTES:
                        return False  # a header word of an object whose payload is secret
                if (base and "ptr:" + x86_reg(base) in state) or (idx and "ptr:" + x86_reg(idx) in state):
                    return True  # read through a pointer to secrets
                slots = stack_slots(o)
                if slots is not None:
                    return "pushed" in state or stack_tagged(slots, "slot:")
                # Unknown memory might alias secret storage; fail closed on its value.
                return not op.startswith("lea")
            return False

        def write(o, value, pointer=False):
            if o.startswith("%"):
                r = x86_reg(o)
                state.discard("entry:" + r)
                if value:
                    state.add(r)
                else:
                    state.discard(r)
                (state.add if pointer else state.discard)("ptr:" + r)
                state.discard("stackaddr:" + r)
                for tag in [t for t in state if t.startswith(("rspoff:" + r + ":", "const:" + r + ":", "zero:" + r))]:
                    state.discard(tag)
                if r != "rsp":
                    state.discard("stackbase:" + r)
            else:
                m = mem_parts(o)
                if m:
                    base, idx = m.group(2), m.group(3)
                    if base and tainted(base) or idx and tainted(idx):
                        raise Violation(f"secret address: {text}")
                    slots = stack_slots(o)
                    if header_args and value and (slots is None or (
                            (base and "ptr:" + x86_reg(base) in state) or (idx and "ptr:" + x86_reg(idx) in state))):
                        # A secret stored anywhere but this function's own frame could land in a header word the
                        # checker reads as public: through a pointer to the object, through a copy of it, or into
                        # static memory the object may be.
                        raise Violation(f"secret stored through an object pointer or outside the frame: {text}")
                    slots = stack_slots(o)
                    if slots is not None:
                        for slot in slots:
                            (state.add if value else state.discard)("slot:" + slot)
                            (state.add if pointer else state.discard)("ptrslot:" + slot)

        if op.startswith("j") and op not in ("jmp", "jmpq"):
            if "flags" in state:
                raise Violation(f"secret branch{trap_note(text)}: {text}")
            return frozenset(state)
        if op.startswith(("jmp",)):
            if ops and (ops[0].startswith("*")):
                raise Violation(f"indirect jump: {text}")
            tail = re.match(r"^(?:0x)?([0-9a-f]+) <([^>+]+)>$", ops[0]) if ops else None
            if tail and int(tail.group(1), 16) not in index_of_lines:
                # A jump out of the function: a call that returns for us.
                if not FOLLOW["path"]:
                    raise Violation(f"call: {text}")
                returned.append(after_call(state, tail.group(2), text))
            return frozenset(state)
        if op.startswith("call"):
            target = ops[0] if ops else ""
            callee = re.search(r"<([^>+]+)>$", target)
            if not FOLLOW["path"] or not callee:
                raise Violation(f"call: {text}")
            return after_call(state, callee.group(1), text)
        if op.startswith(("ret", "nop", "endbr", "ud2", "int3", "hlt")) or op == "":
            return frozenset(state)
        if op in ("cqto", "cqo", "cltd", "cdq", "cwtd", "cwd"):
            # Sign-extends rax into rdx: rdx is a function of rax alone, whatever it held.
            if "rax" in state:
                state.add("rdx")
            else:
                state.discard("rdx")
            return frozenset(state)
        if re.match(r"^(i?div)[bwlq]?$", op):
            if any(read(o) for o in ops) or "rax" in state or "rdx" in state:
                raise Violation(f"secret division: {text}")
        # We do not assign concrete offsets across stack-pointer changes. Once
        # a tagged slot exists, a later adjustment makes stack aliases unknown.
        changes_sp = (op.startswith(("push", "pop")) or
                      (ops and ops[-1] in ("%rsp", "%esp") and
                       op.startswith(("add", "sub", "lea", "mov"))))
        if changes_sp and any(item.startswith(("slot:", "ptrslot:")) for item in state):
            state.add("stack-moved")
        if op.startswith("push"):
            if tainted(ops[0]):
                state.add("pushed")
            if read_pointer(ops[0]):
                state.add("pushed_ptr")
            # The 8 bytes a push of a public register writes hold no secret: a wipe that stops just under them
            # still leaves nothing behind (what a --fast build's ctScrubStack does after `push %rbp`). By the
            # taint here, never by register name; dropped at a pop and at any store to memory.
            here = rsp_delta(state)
            if here != "?":
                for tag in [t for t in state if t.startswith((f"pubpush:{-int(here)}", f"entrypush:{-int(here)}:"))]:
                    state.discard(tag)
                if ops[0].startswith("%") and "entry:" + x86_reg(ops[0]) in state:
                    # The caller's value: the caller decides whether it was public (after_call).
                    state.add(f"entrypush:{-int(here)}:{x86_reg(ops[0])}")
                elif ops[0].startswith("%") and not tainted(ops[0]) and not read_pointer(ops[0]):
                    state.add(f"pubpush:{-int(here)}")
            return frozenset(state)
        if op.startswith("pop"):
            for tag in [t for t in state if t.startswith(("pubpush:", "entrypush:"))]:
                if rsp_delta(state) == "?" or int(tag.split(":")[1]) < -int(rsp_delta(state)):
                    state.discard(tag)
            write(ops[0], "pushed" in state, "pushed_ptr" in state)
            return frozenset(state)
        if ops and not ops[-1].startswith(("%", "$")) and not op.startswith(("cmp", "test", "j", "call", "nop")) and \
                not (repeated and op.startswith("stos")):
            for tag in [t for t in state if t.startswith(("pubpush:", "entrypush:"))]:
                state.discard(tag)
        if op.startswith(("cmp", "test", "vptest", "ptest", "bt", "ucomis", "comis")):
            if any(read(o) for o in ops):
                state.add("flags")
            else:
                state.discard("flags")
            return frozenset(state)
        if op.startswith("lea"):
            parts = mem_parts(ops[0])
            base = x86_reg(parts.group(2)) if parts and parts.group(2) else ""
            index = x86_reg(parts.group(3)) if parts and parts.group(3) else ""
            value = base in state or index in state
            pointer_input = "ptr:" + base in state or "ptr:" + index in state
            stack_base = base == "rsp" or "stackbase:" + base in state
            write(ops[1], value, pointer_input)
            if base == "rsp" and not index and ops[1].startswith("%"):
                displacement = parts.group(1)
                state.add(f"rspoff:{x86_reg(ops[1])}:{int(displacement, 0) if displacement not in ('', '-') else 0}")
            if stack_base and ops[1].startswith("%"):
                state.add("stackbase:" + x86_reg(ops[1]))
                state.add("stackaddr:" + x86_reg(ops[1]))
            if stack_base:
                state.add("frameaddr")
            return frozenset(state)
        # A zeroing idiom forgets what it wrote over.
        if (op.startswith(("xor", "pxor", "vpxor", "sub", "xorp")) and len(ops) >= 2 and
                x86_reg(ops[0]) == x86_reg(ops[1]) and ops[0].startswith("%")):
            write(ops[-1], False)
            state.add("zero:" + x86_reg(ops[-1]))
            state.discard("flags")
            return frozenset(state)
        if repeated and op.startswith("stos") and "zero:rax" in state and not tainted("%rax"):
            # `rep stos` of zero over a constant number of elements starting at a constant offset from
            # rsp: it wipes those bytes of the frame (what ctScrubStack emits).
            width = {"b": 1, "w": 2, "l": 4, "q": 8}.get(op[-1], 0)
            start = next((int(t.split(":")[2]) for t in state if t.startswith("rspoff:rdi:")), None)
            count = next((int(t.split(":")[2]) for t in state if t.startswith("const:rcx:")), None)
            if width and start is not None and count is not None:
                covered = {f"rsp:{offset}" for offset in range(start, start + width * count)}
                for tag in [t for t in state if t.startswith(("slot:", "ptrslot:")) and t.split(":", 1)[1] in covered]:
                    state.discard(tag)
                # A wipe that reaches above the stack pointer overwrites the entry's own live frame.
                if start + width * count > 0:
                    raise Violation(f"a wipe reaches above the stack pointer: {text}")
                # It clears a callee's frames when it covers [rsp at the call - depth, rsp at the call): the
                # wipe's own rsp may differ from the call's, and an unknown difference clears nothing.
                here = rsp_delta(state)
                for tag in [t for t in state if t.startswith("dirty:")]:
                    _, at_call, depth = tag.split(":")
                    if here != "?" and at_call != "?":
                        low = int(here) * -1 + start
                        high = int(here) * -1 + start + width * count
                        # The 8 bytes under the stack pointer at a call hold its return address, not a secret.
                        if low <= -int(at_call) - int(depth) and high >= -int(at_call) - 8:
                            state.discard(tag)
                if here != "?":
                    low = -int(here) + start
                    high = low + width * count
                    state.add(f"wipe:{low}:{high}")
                    # Over pushes of public registers, and of the caller's own registers if the caller's taint
                    # finds them public (a second, conditional wipe).
                    regs = []
                    while True:
                        if f"pubpush:{high}" in state:
                            high += 8
                            continue
                        pushed = [t.split(":")[2] for t in state if t.startswith(f"entrypush:{high}:")]
                        if not pushed:
                            break
                        regs.append(pushed[0])
                        high += 8
                    if high != low + width * count:
                        state.add(f"wipe:{low}:{high}" + (":" + "+".join(sorted(set(regs))) if regs else ""))
                state.discard("rdi")
                state.discard("rcx")
                return frozenset(state)
        if op.startswith("mov") and len(ops) == 2 and ops[0].startswith("$") and ops[1].startswith("%"):
            constant = ops[0][1:]
            write(ops[1], False)
            try:
                state.add(f"const:{x86_reg(ops[1])}:{int(constant, 0)}")
            except ValueError:
                pass
            return frozenset(state)
        if op.startswith("mov") and len(ops) == 2:
            pointer = read_pointer(ops[0])
            value = read(ops[0])
            source = x86_reg(ops[0]) if ops[0].startswith("%") else ""
            stack_base = source == "rsp" or "stackbase:" + source in state
            from_stack_address = "stackaddr:" + source in state
            write(ops[1], value, pointer)
            if stack_base and ops[1].startswith("%"):
                state.add("stackbase:" + x86_reg(ops[1]))
            if (stack_base or from_stack_address) and ops[1].startswith("%"):
                state.add("stackaddr:" + x86_reg(ops[1]))
            # mov %rsp, %rbp sets up the frame pointer; it isn't an address given away.
            if (stack_base or from_stack_address) and not (source == "rsp" and ops[1] == "%rbp"):
                state.add("frameaddr")
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
            # Adding to or subtracting from a pointer is still a pointer.
            moves_pointer = (op.startswith(("add", "sub")) and len(ops) == 2 and not inputs and
                             (read_pointer(ops[-1]) or read_pointer(ops[0])))
            destination = x86_reg(ops[-1]) if ops[-1].startswith("%") else None
            # A register that holds an address in our own frame stays one when a constant is added.
            stack_address = (destination is not None and op.startswith(("add", "sub")) and
                             "stackaddr:" + destination in state)
            write(ops[-1], inputs, moves_pointer)
            if destination is not None:
                state.discard("stackaddr:" + destination)
                if stack_address:
                    state.add("stackaddr:" + destination)
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

    states = fixpoint(lines, start, step, successors)
    # What the function can leave in its registers when it returns, for a caller that follows it.
    out = set()
    paths = []
    for i, (_, text) in enumerate(lines):
        if text.split()[0].startswith("ret") and i in states:
            paths.append(states[i])
    paths += list(returned)
    for path in paths:
        out |= {t for t in path if not t.startswith("wipe:")}
    # A wipe counts for a caller only if it happened on every path to a return.
    if paths:
        out |= frozenset.intersection(*[frozenset(t for t in path if t.startswith("wipe:")) for path in paths])
    if FOLLOW["residue"] and not FOLLOW["stack"]:
        # What a function leaves behind when it returns: a secret in a stack slot of its frame is a
        # copy in memory that nothing wipes. Registers are not counted: scratch registers hold
        # secrets all the time and are overwritten, not left in memory.
        residue = sorted(item for item in out if item.startswith("slot:"))
        residue += sorted(f"{item.split(':')[2]} bytes of callee frames" for item in out if item.startswith("dirty:"))
        if residue:
            raise Violation(f"secret residue at return: {', '.join(residue[:4])}")
    return frozenset(out)


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


A64_ARGS = [f"x{i}" for i in range(8)] + [f"v{i}" for i in range(8)]
# Registers a call may change (the AAPCS64 caller-saved ones: x0 to x18, v0 to v7 and v16 to v31); x19 to x30
# and the low halves of v8 to v15 are the callee's to restore. The state keeps v8 to v15 whole across a call, which
# is right for what the ABI guarantees: a caller reads only d8 to d15 after it.
A64_CLOBBERED = [f"x{i}" for i in range(19)] + [f"v{i}" for i in list(range(8)) + list(range(16, 32))]


def a64_split(ops):
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


A64_REGISTER = re.compile(r"\b[wxvbhsdq]\d+(?:\.\w+)?\b")
A64_READS_ALL = re.compile(r"^(cmp|cmn|tst|ccmp|ccmn|fcmp|fccmp|cbz|cbnz|tbz|tbnz|st[a-z0-9]*|prfm|prfum)")
A64_READS_DEST = re.compile(r"^(movk|bfi|bfxil|bfm|ins|bsl|bit|bif|sli|sri|aese|aesd|aesmc|aesimc|mla|mls|fmla|fmls|usra|ssra|umlal|smlal|fmadd)")


def callee_inputs_a64(name):
    """The argument registers (x0 to x7, v0 to v7) a function may read before it writes them: what its straight-line
    start reads first; from the first branch, call or tail call on, every argument not yet written counts as read."""
    written = set()
    read = set()
    for _, text in disassemble(FOLLOW["path"], name):
        parts = text.split(None, 1)
        op = parts[0]
        ops = a64_split(parts[1]) if len(parts) > 1 else []
        regs = [[a64_reg(r) for r in A64_REGISTER.findall(o)] for o in ops]
        if op in ("cbz", "cbnz", "tbz", "tbnz"):
            read |= {r for r in regs[0] if r not in written}
        if op == "ret":
            return read
        if op in ("b", "bl", "blr", "br") or op.startswith("b.") or op in ("cbz", "cbnz", "tbz", "tbnz"):
            return read | (set(A64_ARGS) - written)
        loads = op.startswith(("ldr", "ldur", "ldp", "ldnp", "ldx", "ldar", "ld1", "ld2", "ld3", "ld4"))
        memory = next((i for i, o in enumerate(ops) if "[" in o), None)
        zeroing = op == "eor" and len(ops) == 3 and ops[1] == ops[2]
        if A64_READS_ALL.match(op) and not loads:
            destinations = 0
        elif loads and memory is not None:
            destinations = memory
        else:
            destinations = 1
        for index, rs in enumerate(regs):
            if index < destinations and not (A64_READS_DEST.match(op) and index == 0):
                continue
            if not zeroing:
                read |= {r for r in rs if r not in written}
        for rs in regs[:destinations]:
            written |= set(rs)
    return read | (set(A64_ARGS) - written)


A64_EXTENTS = {}


def a64_immediate(text):
    """The value of `#4096` or `#1, lsl #12`, or None."""
    m = re.fullmatch(r"#(-?(?:0x[0-9a-f]+|[0-9]+))(?:,\s*lsl #(\d+))?", text.strip())
    return None if not m else int(m.group(1), 0) << int(m.group(2) or 0)


def a64_stack_extent(name, seen=()):
    """How many bytes below its caller's stack pointer a function and what it calls can have written: its frame
    (sub sp and pre-index pushes), the red zone below sp (AArch64 leaf functions use up to 128 bytes of it), and
    the deepest callee. Growth it can't evaluate is a Violation, not a guess."""
    if name in seen:
        raise Violation(f"call: recursion into {name}")
    if name in A64_EXTENTS:
        return A64_EXTENTS[name]
    growth = 0
    red_zone = 0
    deepest = 0
    for _, text in disassemble(FOLLOW["path"], name):
        parts = text.split(None, 1)
        op = parts[0]
        ops = a64_split(parts[1]) if len(parts) > 1 else []
        if ops and ops[0] == "sp" and op not in ("str", "stp", "ldr", "ldp"):
            if op == "sub" and len(ops) >= 3 and ops[1] == "sp":
                value = a64_immediate(", ".join(ops[2:]))
                if value is None:
                    raise Violation(f"call: the stack growth of {name} can't be evaluated: {text}")
                growth += value
            elif op == "add" and len(ops) == 3 and ops[1] == "sp" and a64_immediate(ops[2]) is not None:
                pass  # an epilogue: the stack gets shallower
            elif (op == "mov" and ops[1:] == ["x29"]) or (op == "add" and len(ops) == 3 and ops[1] == "x29"):
                pass  # sp restored from the frame register
            else:
                raise Violation(f"call: the stack growth of {name} can't be evaluated: {text}")
        for index, operand in enumerate(ops):
            pre = re.fullmatch(r"\[sp,\s*#(-(?:0x[0-9a-f]+|[0-9]+))\]!", operand)
            if pre:
                growth += -int(pre.group(1), 0)
            post = operand == "[sp]" and index + 1 < len(ops) and a64_immediate(ops[index + 1])
            if post and post < 0:
                growth += -post
            plain = re.fullmatch(r"\[sp,\s*#(-(?:0x[0-9a-f]+|[0-9]+))\]", operand)
            if plain:
                red_zone = max(red_zone, -int(plain.group(1), 0))
        target = re.fullmatch(r"(?:bl|b)\s+(?:0x)?[0-9a-f]+ <([^>+]+)>", text)
        if target and target.group(1) != name:
            deepest = max(deepest, a64_stack_extent(target.group(1), seen + (name,)))
    A64_EXTENTS[name] = growth + red_zone + deepest
    return A64_EXTENTS[name]


def a64_scrub_bytes(name):
    """How many bytes below sp a function wipes if it is exactly what ctScrubStack emits (the zeroing loop from
    sp - N up to sp), else None."""
    body = [(address, text) for address, text in disassemble(FOLLOW["path"], name)
            if text.split()[0] not in ("paciasp", "autiasp", "bti", "hint", "nop")]
    if len(body) != 6:
        return None
    lines = [text for _, text in body]
    first = re.fullmatch(r"sub\s+x9,\s*sp,\s*(#.*)", lines[0])
    size = a64_immediate(first.group(1)) if first else None
    branch = re.fullmatch(r"b\.ne\s+(?:0x)?([0-9a-f]+)\b.*", lines[4])
    if (size and size > 0 and re.fullmatch(r"mov\s+x10,\s*sp", lines[1]) and
            re.fullmatch(r"stp\s+xzr,\s*xzr,\s*\[x9\],\s*#(?:16|0x10)", lines[2]) and
            re.fullmatch(r"cmp\s+x9,\s*x10", lines[3]) and branch and int(branch.group(1), 16) == body[2][0] and
            lines[5] == "ret" and size % 16 == 0):
        return size
    return None


def follow_call_a64(name, tags, text):
    """follow_call for the AArch64 checker: the callee starts with exactly these register tags."""
    return follow_call(name, sorted(tags), [], text, check=check_aarch64)


A64_STORES = {"str", "stur", "strb", "strh", "sturb", "sturh", "stp", "stnp"}
# Instructions that write no general register (a store's status-writing forms, such as stxr, are not among them).
A64_NO_REGISTER_WRITE = A64_STORES | {"cmp", "cmn", "tst", "ccmp", "ccmn", "fcmp", "b", "br", "ret", "cbz", "cbnz", "tbz",
                                      "tbnz", "nop", "hint", "bti"}


def a64_access_width(op, destination):
    """The bytes a plain load into `destination` touches; 0 if the instruction is anything else."""
    if op in ("ldr", "ldur"):
        return {"w": 4, "x": 8, "b": 1, "h": 2, "s": 4, "d": 8, "q": 16}.get(destination.strip().lower()[:1], 0)
    return {"ldrb": 1, "ldurb": 1, "ldrh": 2, "ldurh": 2, "ldrsb": 1, "ldursb": 1, "ldrsh": 2, "ldursh": 2,
            "ldrsw": 4, "ldursw": 4}.get(op, 0)


def check_aarch64(lines, secret, pointers):
    function_addresses = {address for address, _ in lines}
    header_args = FOLLOW.get("header_args", [])
    FOLLOW["header_args"] = []  # a followed callee has none
    # A spec gives argument numbers; a followed call gives the register tags it passes (x0, v1, ptr:x2).
    start = (frozenset(i if isinstance(i, str) else f"x{i}" for i in secret) |
             frozenset(f"ptr:x{i}" for i in pointers) | frozenset(["spd:0"]) |
             frozenset(f"hdrp:x{i}" for i in header_args))
    returned = []

    def mark_lost(state, op, ops):
        """As on x86-64: a header-public pointer is one only while its register is never written. A call, or any
        bare register operand of an instruction that isn't a compare, branch or store, or a base written back, ends it."""
        if op in ("bl", "blr"):
            state.update("lost:x%d" % i for i in range(19))
            return
        if op in A64_NO_REGISTER_WRITE or op.startswith("b."):
            for o in ops:
                if "[" in o and ("!" in o or (o != ops[-1] and op in A64_STORES)):
                    state.update("lost:" + a64_reg(r) for r in re.findall(r"\b[xw]\d+\b", o))
            return
        for k, o in enumerate(ops):
            if "[" in o:
                if "!" in o or k != len(ops) - 1:
                    state.update("lost:" + a64_reg(r) for r in re.findall(r"\b[xw]\d+\b", o))
            else:
                state.update("lost:" + a64_reg(r) for r in re.findall(r"\b[xwvbhsdq]\d+\b", o))

    def after_call(state, name, text):
        """The state after a call to a function of the same object, checked as a function of its own on the
        arguments the caller passes (only those it reads): what it hands back in x0, x1 and the vector
        registers is what its own analysis found, the other caller-saved registers are dead, x19 and up stay."""
        state = set(state)
        if name == "abla_platform_panic":
            # A panic ends the program, so what it does isn't read; it is reached only on a branch already
            # required to be public, and no secret goes in (its one argument is a message).
            if "x0" in state or "ptr:x0" in state:
                raise Violation(f"call: a panic is given a secret or a pointer to one: {text}")
            return frozenset(state)
        inputs = callee_inputs_a64(name)
        passed = frozenset(r for r in A64_ARGS if r in state and r in inputs)
        pointed = frozenset("ptr:" + r for r in A64_ARGS if "ptr:" + r in state and r not in state and r in inputs)
        out = follow_call_a64(name, passed | pointed, text)
        here = tag_value(state, "spd:")
        wiped = a64_scrub_bytes(name) if FOLLOW["residue"] else None
        if wiped:
            # The callee zeroes [sp - wiped, sp) of the stack pointer it was called with (bl keeps sp). What it
            # clears of a callee's earlier frames is what that range covers; the entry's own frame is above sp.
            for tag in [t for t in state if t.startswith("dirty:")]:
                _, at_call, depth = tag.split(":")
                if here is not None and at_call != "?":
                    if here <= int(at_call) and here + wiped >= int(at_call) + int(depth):
                        state.discard(tag)
        elif FOLLOW["residue"] and (passed or pointed):
            # Whatever the callee wrote below our stack pointer may hold a secret; a wipe has to reach it.
            state.add(f"dirty:{'?' if here is None else here}:{a64_stack_extent(name)}")
        frame_address = any(item.startswith(("stackbase:", "ptrslot:")) for item in state)
        for r in A64_CLOBBERED:
            for tag in (r, "ptr:" + r, "stackbase:" + r):
                state.discard(tag)
            if r in out:
                state.add(r)
            if "ptr:" + r in out:
                state.add("ptr:" + r)
        state.discard("flags")
        # Memory it was given may now hold secrets. Once the function has made an address in its own frame
        # (from sp), it may have been passed or kept in a callee-saved register, and the callee may have
        # written through it: every slot read after a call is secret.
        if frame_address:
            state.add("frame-dirty")
        return frozenset(state)

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

    def tag_value(state, prefix):
        values = [t.split(":")[1] for t in state if t.startswith(prefix)]
        return int(values[0]) if len(values) == 1 and values[0] != "?" else None

    def set_tag(state, prefix, value):
        for tag in [t for t in state if t.startswith(prefix)]:
            state.discard(tag)
        state.add(prefix + ("?" if value is None else str(value)))

    def stack_bytes(memory, register, op, index=0, state=frozenset()):
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
        # While the stack pointer and the frame register are known numbers of bytes below the stack pointer at
        # entry, a slot is named by its distance from that point, so sp- and x29-relative accesses to one
        # byte agree; otherwise it is named by its base register and aliases of another base are assumed.
        below = tag_value(state, "spd:") if match.group(1) == "sp" else tag_value(state, "fpd:")
        if below is not None:
            return [f"slot:f:{offset - below + i}" for i in range(size)]
        return [f"slot:{match.group(1)}:{offset + i}" for i in range(size)]

    def step_inner(state, text, address):
        state = set(state)
        parts = text.split(None, 1)
        op = parts[0]
        ops = split(parts[1]) if len(parts) > 1 else []
        regs = lambda o: [a64_reg(r) for r in re.findall(r"\b[wxvbhsdq]\d+(?:\.\w+)?\b|\bsp\b", o)]
        t = lambda o: any(r in state for r in regs(o))
        if header_args:
            mark_lost(state, op, ops)
        if op.startswith("b.") or A64_BRANCH_REG.match(op):
            if op.startswith("b."):
                if "flags" in state:
                    raise Violation(f"secret branch: {text}")
            elif t(ops[0]):
                raise Violation(f"secret branch: {text}")
            return frozenset(state)
        if op == "b":
            # A jump out of the function is a call that returns for us (a tail call).
            target = re.search(r"0x([0-9a-f]+)\s*<([^>+]+)>", text)
            if target and int(target.group(1), 16) not in function_addresses:
                if not FOLLOW["path"]:
                    raise Violation(f"call: {text}")
                returned.append(after_call(state, target.group(2), text))
            elif target is None and re.search(r"0x([0-9a-f]+)", text) and \
                    int(re.search(r"0x([0-9a-f]+)", text).group(1), 16) not in function_addresses:
                raise Violation(f"call: {text}")
            return frozenset(state)
        if op in ("ret", "nop", "brk", "hint", "bti", "paciasp", "autiasp", "udf", "dmb"):
            return frozenset(state)
        if op == "bl":
            callee = re.search(r"<([^>+]+)>\s*$", text)
            if not FOLLOW["path"] or not callee:
                raise Violation(f"call: {text}")
            return after_call(state, callee.group(1), text)
        if op in ("blr", "br"):
            raise Violation(f"call: {text}")
        stack_change = (op in ("add", "sub", "mov") and ops and ops[0] == "sp") or (
            op.startswith(("ldr", "ldp", "str", "stp")) and
            any("[sp" in operand and ("!" in operand or len(ops) > ops.index(operand) + 1)
                for operand in ops)
        )
        if stack_change and tag_value(state, "spd:") is None and (
                any(item.startswith(("slot:", "ptrslot:")) for item in state) or
                any("ptr:" + a64_reg(operand) in state or t(operand) for operand in ops[:2])):
            state.add("stack-moved")

        def tagged(slots, prefix):
            if any(prefix + slot in state for slot in slots):
                return True
            base = slots[0].split(":", 2)[1]
            return any(item.startswith(prefix + "slot:") and (
                "stack-moved" in state or not item.startswith(prefix + "slot:" + base + ":")
            ) for item in state)
        if op in ("sdiv", "udiv") and any(t(o) for o in ops[1:]):
            raise Violation(f"secret division: {text}")
        if op.startswith("ld"):
            memory = next(o for o in ops if "[" in o)
            inner = regs(memory)
            if any(r in state for r in inner):
                raise Violation(f"secret address: {text}")
            dests = ops[:ops.index(memory)]
            header = re.fullmatch(r"\[(x\d+)(?:,\s*#(0x[0-9a-f]+|\d+))?\]", memory)
            width = a64_access_width(op, dests[0]) if len(dests) == 1 else 0
            public_header = bool(header and width and "hdrp:" + a64_reg(header.group(1)) in state and
                                 "lost:" + a64_reg(header.group(1)) not in state and
                                 int(header.group(2) or "0", 0) + width <= HEADER_BYTES)
            for i, d in enumerate(dests):
                r = a64_reg(d)
                pointer_base = any("ptr:" + reg in state for reg in inner)
                frame = not inner or inner[0] != "x29" or "stackbase:x29" in state
                slots = None if pointer_base or not frame else stack_bytes(memory, d, op, i, state)
                value = (tagged(slots, "") or "frame-dirty" in state) if slots is not None else not public_header
                pointer = slots is not None and tagged(slots, "ptr")
                (state.add if value else state.discard)(r)
                (state.add if pointer else state.discard)("ptr:" + r)
                state.discard("stackbase:" + r)
            if "!" in memory or (len(ops) > len(dests) + 1):
                pass
            return frozenset(state)
        if op.startswith("st"):
            memory = next(o for o in ops if "[" in o)
            inner = regs(memory)
            if any(r in state for r in inner):
                raise Violation(f"secret address: {text}")
            sources = ops[:ops.index(memory)]
            if header_args and any(t(source) for source in sources) and any("ptr:" + reg in state for reg in inner):
                raise Violation(f"secret stored through an object pointer: {text}")
            for i, source in enumerate(sources):
                pointer_base = any("ptr:" + reg in state for reg in inner)
                frame = not inner or inner[0] != "x29" or "stackbase:x29" in state
                slots = None if pointer_base or not frame else stack_bytes(memory, source, op, i, state)
                if header_args and t(source) and slots is None:
                    # Not this function's own frame: static memory could be the object whose header is read as public.
                    raise Violation(f"secret stored through an object pointer or outside the frame: {text}")
                if slots is not None:
                    pointer = "ptr:" + a64_reg(source) in state
                    for slot in slots:
                        (state.add if t(source) else state.discard)(slot)
                        (state.add if pointer else state.discard)("ptr" + slot)
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
        pointer_source = any("ptr:" + a64_reg(source) in state for source in ops[1:])
        if op in ("mov", "add", "sub") and pointer_source and dest != "sp":
            state.add("ptr:" + dest)
            state.discard("stackbase:" + dest)
            (state.add if value else state.discard)(dest)
            return frozenset(state)
        if op in ("mov", "add", "sub") and (src == "sp" or "stackbase:" + src in state) and dest != "sp":
            state.add("stackbase:" + dest)
            state.discard("ptr:" + dest)
            (state.add if value else state.discard)(dest)
            return frozenset(state)
        # A zeroing idiom.
        if op == "eor" and len(ops) == 3 and ops[1] == ops[2]:
            value = False
        (state.add if value else state.discard)(dest)
        state.discard("ptr:" + dest)
        state.discard("stackbase:" + dest)
        if A64_FLAGS.match(op):
            (state.add if value else state.discard)("flags")
        return frozenset(state)

    def step(state_in, text, address):
        """step_inner, then the new distances of sp and x29 below the stack pointer at entry (spd, fpd)."""
        out = set(step_inner(state_in, text, address))
        parts = text.split(None, 1)
        op = parts[0]
        ops = split(parts[1]) if len(parts) > 1 else []
        spd = tag_value(state_in, "spd:")
        fpd = tag_value(state_in, "fpd:") if "stackbase:x29" in state_in else None
        number = lambda o: int(o.lstrip("#"), 0) if re.fullmatch(r"#-?(?:0x[0-9a-f]+|[0-9]+)", o) else None
        new_sp = spd
        if ops and ops[0] == "sp" and op in ("add", "sub", "mov"):
            if op in ("add", "sub") and len(ops) == 3 and ops[1] == "sp" and number(ops[2]) is not None:
                new_sp = None if spd is None else spd + (number(ops[2]) if op == "sub" else -number(ops[2]))
            elif op == "mov" and len(ops) == 2 and ops[1] == "x29":
                new_sp = fpd
            elif op == "add" and len(ops) == 3 and ops[1] == "x29" and number(ops[2]) is not None:
                new_sp = None if fpd is None else fpd - number(ops[2])
            else:
                new_sp = None
        for index, operand in enumerate(ops):
            pre = re.fullmatch(r"\[sp,\s*#(-?(?:0x[0-9a-f]+|[0-9]+))\]!", operand)
            if pre and op.startswith(("ldr", "ldp", "str", "stp")):
                new_sp = None if new_sp is None else new_sp - int(pre.group(1), 0)
            elif operand == "[sp]" and index + 1 < len(ops) and number(ops[index + 1]) is not None:
                new_sp = None if new_sp is None else new_sp - number(ops[index + 1])
        set_tag(out, "spd:", new_sp)
        if new_sp is None and spd is not None and any(i.startswith(("slot:", "ptrslot:")) for i in out):
            out.add("stack-moved")
        # x29: a frame address (x29 = sp + n), or anything else written to it.
        written = [a64_reg(o) for o in ops[:2]] if op.startswith(("ldp", "ldnp")) else (
            [a64_reg(ops[0])] if ops and not op.startswith(("str", "stp", "stur", "cmp", "cmn", "tst", "b", "cb", "tb"))
            else [])
        if "x29" in written:
            if op in ("add", "mov") and ops[1] == "sp" and spd is not None:
                set_tag(out, "fpd:", spd - (number(ops[2]) if len(ops) == 3 and number(ops[2]) is not None else 0)
                        if len(ops) == 2 or number(ops[2]) is not None else None)
            else:
                set_tag(out, "fpd:", None)
        elif not any(t.startswith("fpd:") for t in out) and any(t.startswith("fpd:") for t in state_in):
            set_tag(out, "fpd:", tag_value(state_in, "fpd:"))
        return frozenset(out)

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

    states = fixpoint(lines, start, step, successors)
    # What the function leaves in its registers when it returns, for a caller that follows it.
    out = set()
    for i, (_, text) in enumerate(lines):
        if text.split()[0] == "ret" and i in states:
            out |= states[i]
    for path in returned:
        out |= path
    if FOLLOW["residue"] and not FOLLOW["stack"]:
        # A secret in a slot of the entry's frame is a copy in memory that nothing wipes, and so are the frames of
        # a callee it gave a secret to, unless a wipe below sp covered them.
        residue = sorted(item for item in out if item.startswith("slot:"))
        residue += sorted(f"{item.split(':')[2]} bytes of callee frames" for item in out if item.startswith("dirty:"))
        if residue:
            raise Violation(f"secret residue at return: {', '.join(residue[:4])}")
    return frozenset(out)


# --- Xtensa (windowed ABI: arguments in a2 up) ----------------------------------------------
XT_BRANCH = re.compile(r"^(beq|bne|bge|blt|bgeu|bltu|bany|bnone|ball|bnall|bbc|bbs|beqz|bnez|bgez|bltz|beqi|bnei|bgei|blti|bgeui|bltui|bbci|bbsi)(\.n)?$")
XT_COND_MOVE = re.compile(r"^(moveqz|movnez|movltz|movgez)")


XT_ARGS = [f"a{i}" for i in range(2, 8)]
XT_PURE_LIBCALLS = {"__divdi3", "__udivdi3", "__moddi3", "__umoddi3", "__muldi3", "__ashldi3", "__lshrdi3", "__ashrdi3"}


def callee_inputs_xtensa(name):
    """The argument registers (a2 to a7) a function may read before it writes them, as for the other targets."""
    written = set()
    read = set()
    for _, text in disassemble(FOLLOW["path"], name, ["--mcpu=esp32"]):
        parts = text.split(None, 1)
        op = parts[0]
        ops = [o.strip() for o in parts[1].split(",")] if len(parts) > 1 else []
        if op in ("retw", "retw.n"):
            return read
        if XT_BRANCH.match(op):
            read |= {o for o in ops[:-1] if re.fullmatch(r"a\d+", o)} - written
            return read | (set(XT_ARGS) - written)
        if op in ("j", "j.n") or op.startswith(("call", "jx")):
            return read | (set(XT_ARGS) - written)
        stores = op in ("s8i", "s16i", "s32i", "s32i.n", "s32c1i", "s32ri")
        for index, operand in enumerate(ops):
            if re.fullmatch(r"a\d+", operand) and (stores or index > 0):
                if not (op == "xor" and ops[1] == ops[2]):
                    read |= {operand} - written
        if ops and not stores and re.fullmatch(r"a\d+", ops[0]) and op not in ("entry", "memw"):
            written.add(ops[0])
    return read | (set(XT_ARGS) - written)


def follow_call_xtensa(name, tags, text):
    """follow_call for the Xtensa checker: the callee starts with exactly these register tags (its a2 to a7)."""
    FOLLOW["followed"].add(name)
    key = ("xtensa", name, tuple(tags))
    if key in FOLLOW["done"]:
        return FOLLOW["done"][key]
    if name in FOLLOW["stack"]:
        raise Violation(f"call: recursion into {name}: {text}")
    try:
        lines = disassemble(FOLLOW["path"], name, ["--mcpu=esp32"])
    except (SystemExit, subprocess.CalledProcessError):
        raise Violation(f"call: {name} isn't defined in the object: {text}")
    unread = [t for _, t in lines if "unknown" in t]
    if unread:
        raise Violation(f"call: the disassembler can't read {name}: {unread[0]}")
    FOLLOW["stack"].append(name)
    try:
        returned = check_xtensa(lines, sorted(tags), [])
    except Violation as violation:
        raise Violation(f"in {name}: {violation}")
    finally:
        FOLLOW["stack"].pop()
    FOLLOW["done"][key] = returned
    return returned


def check_xtensa(lines, secret, pointers):
    # A u64 takes an aligned pair of registers, so positions don't map one to one: any secret
    # parameter makes all the argument registers secret, and only pointer lists are exact.
    # (A pointer parameter is an `int`, so also a pair: the address is the low one.)
    returned = []
    header_args = FOLLOW.get("header_args", [])
    FOLLOW["header_args"] = []  # a followed callee has none
    if secret and isinstance(secret[0], str):
        start, secret, pointers = frozenset(secret), [], []
    else:
        start = frozenset(f"ptr:a{2 + 2 * i}" for i in pointers)
    start = start | frozenset(f"hdrp:a{2 + 2 * i}" for i in header_args)
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

    def after_call(state, rotation, name, text):
        if name in XT_PURE_LIBCALLS:
            return pure_libcall(state, rotation, name, text)
        return after_followed_call(state, rotation, name, text)

    def pure_libcall(state, rotation, name, text):
        """A compiler-rt arithmetic helper (no loads of its own beyond its arguments): with public arguments its
        results are public; a division by a secret or of one is a secret division, any other helper's results
        are as secret as its arguments. __muldi3 is constant-time where the core has the 32-bit multiplier (MUL32: the
        ESP32 and ESP32-S3 do), which is what the secret-operand propagation here relies on."""
        state = set(state)
        arguments = [f"a{rotation + k}" for k in range(2, 6) if rotation + k <= 15]  # two 64-bit operands
        secret = any(a in state for a in arguments)
        if any(f"ptr:{a}" in state for a in arguments):
            raise Violation(f"call: {name} is given a pointer to a secret: {text}")
        if secret and re.match(r"^__u?(div|mod)", name):
            raise Violation(f"secret division: {text}")
        if re.match(r"^__(ashl|lshr|ashr)di3$", name) and f"a{rotation + 4}" in state:
            # The count is the third argument word (a4 of the callee); the helpers branch on count >= 32.
            raise Violation(f"secret shift count: {text}")
        for r in range(rotation, 16):
            for tag in (f"a{r}", f"ptr:a{r}", f"stackbase:a{r}"):
                state.discard(tag)
        if secret:
            state.update(f"a{rotation + k}" for k in (2, 3) if rotation + k <= 15)
        return frozenset(state)

    def after_followed_call(state, rotation, name, text):
        """The state after a windowed call to a function of the same object: its a2 to a7 are our a(rotation+2) up,
        checked as a function of its own on the arguments it reads; what it leaves in a2 and up comes back to
        a(rotation+2) and up, and our registers from a(rotation) on are the callee's window (dead)."""
        state = set(state)
        inputs = callee_inputs_xtensa(name)
        tags = set()
        for k in range(2, 8):
            if rotation + k > 15 or f"a{k}" not in inputs:
                continue
            if f"a{rotation + k}" in state:
                tags.add(f"a{k}")
            elif f"ptr:a{rotation + k}" in state:
                tags.add(f"ptr:a{k}")
        out = follow_call_xtensa(name, tags, text)
        # Once an address in this frame was made (anywhere before: it may have been spilled and reloaded) a callee
        # may have written through it.
        frame_address = "frameaddr" in state
        for r in range(rotation, 16):
            for tag in (f"a{r}", f"ptr:a{r}", f"stackbase:a{r}"):
                state.discard(tag)
        for k in range(2, 8):
            if rotation + k <= 15:
                if f"a{k}" in out:
                    state.add(f"a{rotation + k}")
                if f"ptr:a{k}" in out:
                    state.add(f"ptr:a{rotation + k}")
        if frame_address:
            state.add("frame-dirty")
        return frozenset(state)

    def frame_offset(state, register):
        """How far `register` is above a1, when it is a1 itself or a copy of it plus a constant (an unoptimised
        function addresses its frame through such a register), else None."""
        if register == "a1":
            return 0
        values = [tag.split(":")[2] for tag in state if tag.startswith(f"sb:{register}:")]
        return int(values[0]) if len(values) == 1 else None

    def step(state, text, address):
        state = set(state)
        parts = text.split(None, 1)
        op = parts[0]
        ops = [o.strip() for o in parts[1].split(",")] if len(parts) > 1 else []
        t = lambda o: o in state
        if header_args:
            # A header-public pointer is one only while its register is never written: a call (the window moves and
            # the callee may write through it), or any instruction naming it first, other than a store or a branch.
            if op.startswith(("call", "callx")):
                state.update(f"lost:a{i}" for i in range(16))
            elif ops and not XT_BRANCH.match(op) and not op.startswith(("s8i", "s16i", "s32i", "j", "ret", "nop", "memw")):
                state.add("lost:" + ops[0])
        if XT_BRANCH.match(op):
            if any(t(o) for o in ops[:-1]):
                raise Violation(f"secret branch: {text}")
            return frozenset(state)
        if op in ("j", "j.n", "retw", "retw.n", "ret", "ret.n", "nop", "nop.n", "memw", "entry", "ill", "ill.n"):
            return frozenset(state)
        call = re.match(r"^call(4|8|12)\s+\S+\s+<([^>+]+)>$", text)
        if call and FOLLOW["path"]:
            return after_call(state, int(call.group(1)), call.group(2), text)
        if op.startswith(("call", "callx", "jx")):
            raise Violation(f"call: {text}")
        if ops and ops[0] == "a1" and op in ("addi", "addi.n", "add", "add.n", "addmi", "mov", "mov.n"):
            if any(item.startswith(("slot:", "ptrslot:")) for item in state):
                state.add("stack-moved")
        if op in ("quos", "quou", "rems", "remu") and any(t(o) for o in ops[1:]):
            raise Violation(f"secret division: {text}")
        m = re.match(r"^(l8ui|l16ui|l16si|l32i|l32i\.n)$", op)
        if m:
            dest, base, offset = ops[0], ops[1], ops[2] if len(ops) > 2 else "0"
            if t(base):
                raise Violation(f"secret address: {text}")
            size = 1 if op.startswith("l8") else 2 if op.startswith("l16") else 4
            at = frame_offset(state, base)
            slots = [f"slot:{at + int(offset, 0) + i}" for i in range(size)] if at is not None else []
            public_header = ("hdrp:" + base in state and "lost:" + base not in state and
                             re.fullmatch(r"-?(0x[0-9a-f]+|\d+)", offset) is not None and 0 <= int(offset, 0) < HEADER_BYTES)
            value = (any(slot in state for slot in slots) or "frame-dirty" in state or (
                "stack-moved" in state and any(item.startswith("slot:") for item in state)
            )) if slots else not public_header
            pointer = any("ptr" + slot in state for slot in slots) or (
                bool(slots) and "stack-moved" in state and any(item.startswith("ptrslot:") for item in state)
            )
            (state.add if value else state.discard)(dest)
            (state.add if pointer else state.discard)("ptr:" + dest)
            return frozenset(state)
        m = re.match(r"^(s8i|s16i|s32i|s32i\.n)$", op)
        if m:
            source, base, offset = ops[0], ops[1], ops[2] if len(ops) > 2 else "0"
            if t(base):
                raise Violation(f"secret address: {text}")
            at = frame_offset(state, base)
            if header_args and t(source) and at is None:
                raise Violation(f"secret stored through an object pointer or outside the frame: {text}")
            if at is not None:
                size = 1 if op.startswith("s8") else 2 if op.startswith("s16") else 4
                for i in range(size):
                    slot = f"slot:{at + int(offset, 0) + i}"
                    (state.add if t(source) else state.discard)(slot)
                    (state.add if "ptr:" + source in state else state.discard)("ptr" + slot)
            return frozenset(state)
        if op == "l32r":
            state.discard(ops[0])
            state.discard("ptr:" + ops[0])
            return frozenset(state)
        if not ops:
            return frozenset(state)
        dest = ops[0]
        value = any(t(o) for o in ops[1:])
        if XT_COND_MOVE.match(op):
            value = value or t(dest)
        if op in ("xor",) and ops[1] == ops[2]:
            value = False
        # Registers that are a1 plus a constant, or a constant (a big frame is addressed through `movi aN, 1440` and
        # `add.n aD, a7, aN`).
        constant = lambda register: next((int(x.split(":")[2]) for x in state if x.startswith(f"const:{register}:")), None)
        fresh = []
        if op in ("movi", "movi.n") and len(ops) == 2:
            fresh.append(f"const:{dest}:{int(ops[1], 0)}")
        elif op in ("mov", "mov.n") and len(ops) == 2:
            if frame_offset(state, ops[1]) is not None:
                fresh.append(f"sb:{dest}:{frame_offset(state, ops[1])}")
            if constant(ops[1]) is not None:
                fresh.append(f"const:{dest}:{constant(ops[1])}")
        elif op in ("addi", "addi.n", "addmi") and len(ops) == 3:
            step_by = int(ops[2], 0) * (256 if op == "addmi" else 1)
            if frame_offset(state, ops[1]) is not None:
                fresh.append(f"sb:{dest}:{frame_offset(state, ops[1]) + step_by}")
            if constant(ops[1]) is not None:
                fresh.append(f"const:{dest}:{constant(ops[1]) + step_by}")
        elif op in ("add", "add.n") and len(ops) == 3:
            if frame_offset(state, ops[1]) is not None and constant(ops[2]) is not None:
                fresh.append(f"sb:{dest}:{frame_offset(state, ops[1]) + constant(ops[2])}")
            elif frame_offset(state, ops[2]) is not None and constant(ops[1]) is not None:
                fresh.append(f"sb:{dest}:{frame_offset(state, ops[2]) + constant(ops[1])}")
            if constant(ops[1]) is not None and constant(ops[2]) is not None:
                fresh.append(f"const:{dest}:{constant(ops[1]) + constant(ops[2])}")
        for tag in [x for x in state if x.startswith((f"sb:{dest}:", f"const:{dest}:"))]:
            state.discard(tag)
        state.update(fresh)
        if op in ("addi", "addi.n", "mov", "mov.n", "or", "add", "add.n", "addmi", "addx2", "addx4", "addx8"):
            # An address in this function's frame (a1 plus something): a callee given it may write through it.
            if any(o == "a1" or "stackbase:" + o in state or frame_offset(state, o) is not None for o in ops[1:]):
                state.add("stackbase:" + dest)
                state.add("frameaddr")
            else:
                state.discard("stackbase:" + dest)
        else:
            state.discard("stackbase:" + dest)
        if op in ("addi", "addi.n", "mov", "mov.n", "or", "add", "add.n", "addmi", "addx2", "addx4", "addx8") and \
                any("ptr:" + o in state for o in ops[1:]):
            state.add("ptr:" + dest)
            (state.add if value else state.discard)(dest)
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

    states = fixpoint(lines, start, step, successors)
    # What the function leaves in its registers when it returns, for a caller that follows it.
    out = set()
    for i, (_, text) in enumerate(lines):
        if text.split()[0] in ("retw", "retw.n", "ret", "ret.n") and i in states:
            out |= states[i]
    return frozenset(out)


# --- Wasm ----------------------------------------------------------------------------------
WASM_BINARY = re.compile(r"^(i32|i64|f32|f64|v128|i8x16|i16x8|i32x4|i64x2|f32x4|f64x2)\.(add|sub|mul|and|or|xor|shl|shr_s|shr_u|rotl|rotr|eq|ne|lt_s|lt_u|gt_s|gt_u|le_s|le_u|ge_s|ge_u|div|min|max|lt|gt|le|ge|copysign|andnot|add_sat_s|add_sat_u|sub_sat_s|sub_sat_u)$")
WASM_UNARY = re.compile(r"^(i32|i64|f32|f64|v128|i8x16|i16x8|i32x4|i64x2|f32x4|f64x2)\.(eqz|clz|ctz|popcnt|wrap_i64|extend\w*|trunc\w*|convert\w*|reinterpret\w*|promote\w*|demote\w*|not|neg|abs|sqrt|splat|any_true|all_true|bitmask|extract_lane\w*)\b")


WASM_MODULES = {}


def wasm_leb(data, at):
    value, shift = 0, 0
    while True:
        byte = data[at]
        at += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return value, at


def wasm_module(path):
    """What a call needs of a linked module: the parameter and result counts of its types, which type each
    function has, how many functions are imports (they come first in the index space), and the instructions of
    every defined function in order (names may be stripped, so a call is followed by its index)."""
    if path in WASM_MODULES:
        return WASM_MODULES[path]
    data = open(path, "rb").read()
    types, functions, imports, exports = [], [], 0, {}
    at = 8
    while at < len(data):
        section = data[at]
        size, body = wasm_leb(data, at + 1)
        end = body + size
        if section == 1:
            count, i = wasm_leb(data, body)
            for _ in range(count):
                i += 1  # 0x60
                params, i = wasm_leb(data, i)
                i += params  # one byte a value type
                results, i = wasm_leb(data, i)
                i += results
                types.append((params, results))
        elif section == 2:
            count, i = wasm_leb(data, body)
            for _ in range(count):
                for _ in range(2):  # module and field names
                    length, i = wasm_leb(data, i)
                    i += length
                kind = data[i]
                i += 1
                if kind == 0:
                    _, i = wasm_leb(data, i)
                    imports += 1
                elif kind == 1:
                    i += 1
                    flag = data[i]
                    i += 1
                    _, i = wasm_leb(data, i)
                    if flag & 1:
                        _, i = wasm_leb(data, i)
                elif kind == 2:
                    flag = data[i]
                    i += 1
                    _, i = wasm_leb(data, i)
                    if flag & 1:
                        _, i = wasm_leb(data, i)
                elif kind == 3:
                    i += 2
                else:
                    i += 1
                    _, i = wasm_leb(data, i)
        elif section == 3:
            count, i = wasm_leb(data, body)
            for _ in range(count):
                index, i = wasm_leb(data, i)
                functions.append(index)
        elif section == 7:
            count, i = wasm_leb(data, body)
            for _ in range(count):
                length, i = wasm_leb(data, i)
                name = data[i:i + length].decode("utf-8", "replace")
                i += length
                kind = data[i]
                index, i = wasm_leb(data, i + 1)
                if kind == 0:
                    exports[name] = index
        at = end
    text = subprocess.run([OBJDUMP, "-d", "--no-show-raw-insn", path], capture_output=True, text=True, check=True).stdout
    bodies = []
    for line in text.splitlines():
        if re.match(r"^[0-9a-f]+ <.*>:$", line):
            bodies.append([])
        elif bodies:
            m = re.match(r"^\s*([0-9a-f]+):\s*(.*)$", line)
            if m:
                bodies[-1].append((int(m.group(1), 16), m.group(2).split("//")[0].strip()))
    bodies = bodies[1:]  # the first header is the CODE section itself
    if len(bodies) != len(functions):
        raise Violation(f"call: {path} has {len(functions)} functions but {len(bodies)} disassembled")
    WASM_MODULES[path] = (types, functions, imports, bodies, exports)
    return WASM_MODULES[path]


def wasm_export_lines(path, name):
    """The instructions of the function a module exports under `name` (a module built without a name section has
    no symbol to disassemble by), or None."""
    _types, _functions, imports, bodies, exports = wasm_module(path)
    index = exports.get(name)
    if index is None or index < imports:
        return None
    return bodies[index - imports]


def follow_wasm(index, secret, pointers, text):
    """Check the function `index` of the module on the arguments the caller passes; what it returns, per result."""
    types, functions, imports, bodies, _exports = wasm_module(FOLLOW["path"])
    FOLLOW["followed"].add(f"function {index}")
    if index < imports:
        raise Violation(f"call: function {index} is an import: {text}")
    if index - imports >= len(functions):
        raise Violation(f"call: no function {index} in the module: {text}")
    key = ("wasm", index, tuple(secret), tuple(pointers))
    if key in FOLLOW["done"]:
        return FOLLOW["done"][key]
    if ("wasm", index) in FOLLOW["stack"]:
        raise Violation(f"call: recursion into function {index}: {text}")
    lines = bodies[index - imports]
    results = types[functions[index - imports]][1]
    FOLLOW["stack"].append(("wasm", index))
    try:
        returned = check_wasm(lines, secret, pointers, results)
    except Violation as violation:
        raise Violation(f"in function {index}: {violation}")
    finally:
        FOLLOW["stack"].pop()
    FOLLOW["done"][key] = returned
    return returned


def wasm_load_width(op):
    """The bytes a plain Wasm load reads; 0 for anything else (a splat, an extending vector load, a lane load)."""
    m = re.fullmatch(r"(i32|i64|f32|f64|v128)\.load(\d+)?(_[su])?", op)
    if not m:
        return 0
    if m.group(2):
        return int(m.group(2)) // 8 if m.group(1) in ("i32", "i64") else 0
    return {"i32": 4, "i64": 8, "f32": 4, "f64": 8, "v128": 16}[m.group(1)]


def check_wasm(lines, secret, pointers, results=0):
    # Function parameters are locals. The stack's shape follows from each instruction, and the
    # lines are visited in order several times to carry what locals pick up around loops.
    # Each pass starts at the function's entry; a loop's head joins what its back edges brought in
    # the pass before, and a block's end what branches out of it did, until nothing changes.
    heads = {}
    header_args = FOLLOW.get("header_args", [])
    FOLLOW["header_args"] = []  # a followed callee has none
    # A header-public pointer is a parameter no instruction of the function ever writes, in a function that makes no
    # call (a callee could store a secret through it): locals are untouched by a call, memory is not.
    written = {int(t.split()[1]) for _, t in lines if t.split()[:1] in (["local.set"], ["local.tee"])}
    calls = any(t.split()[:1] and t.split()[0] in ("call", "call_indirect", "call_ref", "return_call",
                                                    "return_call_indirect", "return_call_ref") for _, t in lines)
    header_locals = set() if calls else {i for i in header_args if i not in written}
    for _ in range(64):
        before = {k: (set(v[0]), set(v[1])) for k, v in heads.items()}
        returned = []

        def record_return():
            # The top `results` values of the stack, as the caller of a followed function receives them.
            top = stack[-results:] if results and len(stack) >= results else [(True, False)] * results
            returned.append(top)

        locals_tainted = set(secret)
        pointer_locals = set(pointers)
        stack = []
        control = []
        unreachable = False

        def branch_to(depth):
            if depth >= len(control):
                # The function's own outermost label: a branch to it returns.
                if not unreachable:
                    record_return()
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
                    if not unreachable:
                        record_return()
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
                if op == "return":
                    record_return()
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
                    for depth in range(len(control) + 1):  # the last is the function's own label: a return
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
                value = stack.pop() if stack else (False, False)
                if value[0] or value[1]:
                    raise Violation(f"secret or secret-pointer global store: {text}")
            elif re.match(r"^(i32|i64|f32|f64|v128)\.load", op):
                address_value = stack.pop() if stack else (False, False)
                if address_value[0]:
                    raise Violation(f"secret address: {text}")
                # Linear-memory aliases cannot be distinguished here; treating every
                # load as secret also fails closed if a pointer was spilled there.
                previous = lines[at - 1][1].split() if at else []
                header_word = (header_locals and previous[:1] == ["local.get"] and int(previous[1]) in header_locals and
                               len(parts) > 1 and re.fullmatch(r"\d+", parts[1]) and wasm_load_width(op) and
                               int(parts[1]) + wasm_load_width(op) <= HEADER_BYTES)
                stack.append((not header_word, False))
            elif header_args and op in ("memory.copy", "memory.fill", "memory.init"):
                raise Violation(f"a bulk memory write in a function with a header pointer: {text}")
            elif re.match(r"^(i32|i64|f32|f64|v128)\.store", op):
                _value = stack.pop() if stack else (False, False)
                address_value = stack.pop() if stack else (False, False)
                if header_args and _value[0]:
                    # Any linear-memory address could be the object (or its header); only a pointer proven to be
                    # elsewhere would be safe, and the checker has no such proof.
                    raise Violation(f"secret stored through an object pointer or outside the frame: {text}")
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
            elif op == "call" and FOLLOW["path"] and len(parts) > 1 and parts[1].isdigit():
                index = int(parts[1])
                types, functions, imports, _bodies, _exports = wasm_module(FOLLOW["path"])
                if index < imports or index - imports >= len(functions):
                    raise Violation(f"call: {text}")
                params, outputs = types[functions[index - imports]]
                arguments = [stack.pop() if stack else (False, False) for _ in range(params)][::-1]
                passed = [i for i, a in enumerate(arguments) if a[0]]
                pointed = [i for i, a in enumerate(arguments) if a[1] and not a[0]]
                out = follow_wasm(index, passed, pointed, text)
                for position in range(outputs):
                    column = [row[position] for row in out if len(row) > position]
                    stack.append((any(c[0] for c in column), any(c[1] for c in column)))
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
            return returned
    raise SystemExit("no fixed point")


CHECKERS = {"x86_64": check_x86, "aarch64": check_aarch64, "xtensa": check_xtensa, "wasm": check_wasm}


HEADERS = {}
HEADER_BYTES = 32
HEADER_CHECKERS = ("x86_64", "aarch64", "wasm", "xtensa")


def parse_spec(spec, count_hint=8):
    name, _, roles = spec.partition(":")
    secret, pointers = [], []
    HEADERS[name] = []
    if roles == "*":
        secret = list(range(count_hint))
    elif roles:
        for r in roles.split(","):
            if r.startswith("@"):
                pointers.append(int(r[1:]))
            elif r.startswith("%"):
                # A pointer to an object whose first HEADER_BYTES are public and whose rest is secret.
                pointers.append(int(r[1:]))
                HEADERS[name].append(int(r[1:]))
            else:
                secret.append(int(r))
    return name, secret, pointers


def main():
    arguments = sys.argv[1:]
    if "--residue" in arguments:
        # Checks x86-64 only. A callee followed from a checked function isn't checked for residue
        # itself: its caller's frame and registers are what remain.
        arguments.remove("--residue")
        FOLLOW["residue"] = True
    if "--follow-calls" in arguments:
        arguments.remove("--follow-calls")
        FOLLOW["path"] = arguments[1]
    arch, path, *specs = arguments
    failed = 0
    for spec in specs:
        name, secret, pointers = parse_spec(spec)
        if HEADERS.get(name) and arch not in HEADER_CHECKERS:
            print(f"LEAK {arch} {name}: a header-public pointer (%) isn't read on {arch}")
            failed = 1
            continue
        lines = wasm_export_lines(path, name) if arch == "wasm" else None
        if lines is None:
            lines = disassemble(path, name, ["--mcpu=esp32"] if arch == "xtensa" else [])
        # What the disassembler can't read could be anything: a pass over it would mean nothing.
        unread = [text for _, text in lines if "unknown" in text]
        if unread:
            print(f"LEAK {arch} {name}: the disassembler can't read: {unread[0]}")
            failed = 1
            continue
        FOLLOW["followed"] = set()
        try:
            FOLLOW["header_args"] = list(HEADERS.get(name, []))
            CHECKERS[arch](lines, secret, pointers)
            following = f", following {len(FOLLOW['followed'])}" if FOLLOW["followed"] else ""
            print(f"ok   {arch} {name} ({len(lines)} instructions{following})")
        except Violation as violation:
            print(f"LEAK {arch} {name}: {violation}")
            failed = 1
    sys.exit(failed)


if __name__ == "__main__":
    main()
