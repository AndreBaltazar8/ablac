#!/usr/bin/env python3
"""Regression: x86 three-operand IMUL overwrites, but two-operand IMUL reads, its destination."""
import importlib.util
import sys
from pathlib import Path

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location("ct_check", Path(__file__).with_name("check-asm.py"))
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


def check(code, secret, should_leak):
    lines = list(enumerate(code + ["retq"]))
    try:
        checker.check_x86(lines, secret, [])
    except checker.Violation:
        assert should_leak, code
    else:
        assert not should_leak, code


check(["imulq $3, %rdx, %rdi", "cmpq $0, %rdi", "jne 0x3"], [0], False)
check(["imulq $3, %rdi, %rdx", "cmpq $0, %rdx", "jne 0x3"], [0], True)
check(["imulq %rdx, %rdi", "cmpq $0, %rdi", "jne 0x3"], [0], True)
print("ok   checker: x86 IMUL operand taint")

# A secret-dependent branch to a trap is still a leak: it is only worded as one, so a fast build's type-tag
# check (listed in fast-known.txt) is told from a bounds check on a secret by being listed, never by passing.
def trap_message(code, secret):
    try:
        checker.check_x86(list(enumerate(code)), secret, [])
    except checker.Violation as violation:
        return str(violation)
    return None


bounds = ["cmpq $16, %rdi", "jae 0x3", "retq", "ud2"]
assert "secret branch (to trap)" in trap_message(bounds, [0]), "a secret bounds check to ud2 must be reported"
assert trap_message(bounds, []) is None, "the same check on a public value is clean"
assert "(to trap)" not in trap_message(["cmpq $16, %rdi", "jae 0x3", "retq", "nop", "retq"], [0])
print("ok   checker: a secret branch to a trap is a leak")

# AArch64 immediates are operands, not comments; single and paired stack
# accesses must use the same byte offsets, including partial overwrites.
from types import SimpleNamespace
original_run = checker.subprocess.run
checker.subprocess.run = lambda *args, **kwargs: SimpleNamespace(stdout=(
    "00000000 <example>:\n"
    "  0: ldp x1, x2, [sp, #0x48] // comment\n"
    "  4: mov w3, #0x1\n"
    "  8: ret\n"
))
try:
    parsed = checker.disassemble("ignored", "example")
finally:
    checker.subprocess.run = original_run
assert parsed[0][1] == "ldp x1, x2, [sp, #0x48]", parsed
assert parsed[1][1] == "mov w3, #0x1", parsed


def a64(code, should_leak):
    lines = list(enumerate(code + ["ret"]))
    try:
        checker.check_aarch64(lines, [0], [])
    except checker.Violation:
        assert should_leak, code
    else:
        assert not should_leak, code


a64(["str x0, [sp, #0x50]", "ldp x1, x2, [sp, #0x48]", "cbnz x2, 0x3"], True)
a64(["str x0, [sp, #0x50]", "str x1, [sp, #0x50]", "ldp x1, x2, [sp, #0x48]", "cbnz x2, 0x4"], False)
a64(["str w0, [sp, #0x54]", "ldr x2, [sp, #0x50]", "cbnz x2, 0x3"], True)
a64(["str x0, [sp, #0x50]", "ldr x2, [sp, #0x48]", "cbnz x2, 0x3"], False)
a64(["str x0, [sp, #0x50]", "strb w1, [sp, #0x50]", "ldrb w2, [sp, #0x51]", "cbnz x2, 0x4"], True)
a64(["str x0, [sp, #0x50]", "strb w1, [sp, #0x50]", "ldrb w2, [sp, #0x50]", "cbnz x2, 0x4"], False)
print("ok   checker: AArch64 immediates and stack aliases")

# Public pointers to secret memory retain their provenance across stack spills.
def pointer_check(arch, code, should_leak):
    lines = list(enumerate(code + ["retq" if arch == "x86_64" else "ret"]))
    try:
        checker.CHECKERS[arch](lines, [], [0])
    except checker.Violation:
        assert should_leak, code
    else:
        assert not should_leak, code


pointer_check("x86_64", ["movq %rdi, -0x8(%rsp)", "movq -0x8(%rsp), %rax", "movl (%rax), %eax", "testl %eax, %eax", "je 0x5"], True)
pointer_check("x86_64", ["movq %rdi, -0x8(%rsp)", "movq %rsi, -0x8(%rsp)", "movq -0x8(%rsp), %rax", "movl (%rax), %eax", "testl %eax, %eax", "je 0x6"], True)
pointer_check("x86_64", ["movq %rdi, -0x8(%rsp)", "movb %sil, -0x8(%rsp)", "movq -0x8(%rsp), %rax", "movl (%rax), %eax", "testl %eax, %eax", "je 0x6"], True)
pointer_check("x86_64", ["movq %rdi, %rbp", "movl (%rbp), %eax", "testl %eax, %eax", "je 0x4"], True)
pointer_check("aarch64", ["str x0, [sp]", "ldr x1, [sp]", "ldr w1, [x1]", "cbz w1, 0x4"], True)
pointer_check("aarch64", ["str x0, [sp, #0x50]", "str x1, [sp, #0x50]", "ldr x2, [sp, #0x50]", "ldr w3, [x2]", "cbz w3, 0x5"], True)
pointer_check("aarch64", ["stp x0, x1, [sp, #0x48]", "ldp x2, x3, [sp, #0x48]", "ldr w4, [x2]", "cbz w4, 0x4"], True)
pointer_check("aarch64", ["mov x29, x0", "ldr w1, [x29]", "cbz w1, 0x3"], True)
print("ok   checker: secret-pointer spills and general-purpose frame registers")

# Unknown non-stack memory may alias secret storage even if pointer provenance was lost.
pointer_check("x86_64", ["movl (%rsi), %eax", "testl %eax, %eax", "je 0x3"], True)
pointer_check("aarch64", ["ldr w1, [x2]", "cbz w1, 0x2"], True)
pointer_check("xtensa", ["s32i a2, a1, 0", "l32i a4, a1, 0", "l32i a5, a4, 0", "beqz a5, 0x4"], True)
print("ok   checker: conservative loads and Xtensa pointer spill")

# Wasm linear memory has no shadow stack cells in this checker. A loaded value
# is conservatively secret, so a spilled pointer cannot become a public address.
wasm_spill = ["global.get 0", "local.get 0", "i32.store", "global.get 0", "i32.load", "i32.load", "return"]
try:
    checker.check_wasm(list(enumerate(wasm_spill)), [], [0])
except checker.Violation:
    pass
else:
    raise AssertionError("missed Wasm spilled pointer")
# Loading a secret value is permitted when it is returned without controlling flow.
checker.check_wasm(list(enumerate(["local.get 0", "i32.load", "return"])), [], [0])
print("ok   checker: Wasm linear-memory spill fails closed")

# Changing SP or switching between frame and stack bases must not hide spills.
pointer_check("x86_64", ["movq %rdi, -0x8(%rsp)", "subq $0x10, %rsp", "movq 0x8(%rsp), %rax", "movl (%rax), %eax", "testl %eax, %eax", "je 0x6"], True)
pointer_check("x86_64", ["movq %rsp, %rbp", "movq %rdi, -0x8(%rsp)", "movq -0x8(%rbp), %rax", "movl (%rax), %eax", "testl %eax, %eax", "je 0x6"], True)
pointer_check("aarch64", ["str x0, [sp, #0x10]", "sub sp, sp, #0x10", "ldr x1, [sp, #0x20]", "ldr w2, [x1]", "cbz w2, 0x5"], True)
pointer_check("aarch64", ["mov x29, sp", "str x0, [sp, #0x10]", "ldr x1, [x29, #0x10]", "ldr w2, [x1]", "cbz w2, 0x5"], True)
print("ok   checker: changing stack and frame aliases")

pointer_check("xtensa", ["s32i a2, a1, 0", "addi a1, a1, -16", "l32i a4, a1, 16", "l32i a5, a4, 0", "beqz a5, 0x5"], True)
print("ok   checker: Xtensa changing stack aliases")

# The pointer value itself remains public when a precise stack spill is reloaded.
pointer_check("x86_64", ["movq %rdi, -0x8(%rsp)", "movq -0x8(%rsp), %rax", "testq %rax, %rax", "je 0x4"], False)
pointer_check("aarch64", ["str x0, [sp]", "ldr x1, [sp]", "cbz x1, 0x3"], False)
pointer_check("xtensa", ["s32i a2, a1, 0", "l32i a4, a1, 0", "beqz a4, 0x3"], False)
print("ok   checker: spilled pointer values remain public")

# Pointer provenance must not hide a secret offset used in an address.
def mixed_pointer(arch, code):
    lines = list(enumerate(code + ["retq" if arch == "x86_64" else "ret"]))
    try:
        checker.CHECKERS[arch](lines, [1], [0])
    except checker.Violation:
        return
    raise AssertionError((arch, code))

mixed_pointer("x86_64", ["leaq (%rdi,%rsi), %rax", "movl (%rax), %eax"])
mixed_pointer("aarch64", ["add x2, x0, x1", "ldr w3, [x2]"])
mixed_pointer("xtensa", ["add a5, a2, a4", "l32i a6, a5, 0"])
try:
    checker.check_wasm(list(enumerate(["local.get 0", "global.set 0", "return"])), [], [0])
except checker.Violation:
    pass
else:
    raise AssertionError("missed Wasm secret-pointer global store")
print("ok   checker: secret pointer offsets and Wasm globals")

pointer_check("x86_64", ["pushq %rdi", "movq (%rsp), %rax", "movl (%rax), %eax", "testl %eax, %eax", "je 0x5"], True)
check(["pushq %rdi", "movq (%rsp), %rax", "testq %rax, %rax", "je 0x4"], [0], True)
print("ok   checker: pushed secret pointers and data")
