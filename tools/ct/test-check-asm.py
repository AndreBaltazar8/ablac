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
