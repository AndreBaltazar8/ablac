#!/usr/bin/env python3
"""Rewrite LLVM Xtensa assembly to Code Density (16-bit) forms where exact.

Upstream LLVM's Xtensa code generator rarely selects the narrow (.n)
encodings that Espressif's toolchain uses for ~40% of instructions. Each
rewrite here is a pure re-encoding with identical semantics, within the ISA's
narrow operand ranges. Branches are left alone (narrow branches are
forward-only with short ranges the assembler would have to check) and inline
assembly (#APP ... #NO_APP) is copied verbatim, as is any
.begin no-transform region, because its exact layout may matter.
Shrinking code only shortens distances, so l32r and branch ranges stay valid.

LLVM's text output also places each function's .literal_position/.literal
directives before its `.section .text.<fn>` switch, while the previous
function's jump-table (.rodata) section is current. llvm-mc names literal
pools after the current section, so they would land in `.rodata.<fn>.literal`
(flash data, out of l32r range). Literal runs are therefore held until the
function's text section is current, giving `.literal.<fn>` beside its code.

Call-frame (.cfi_*) directives are dropped unless ABLA_ESP_KEEP_UNWIND=1:
the wrapper strips .eh_frame afterwards anyway, and LLVM 23.1's Xtensa
assembler rejects the frame-pointer form `.cfi_def_cfa a7, N` it emits.
"""

from __future__ import annotations

import os
import re
import sys

REG = r"a(?:1[0-5]|[0-9])"
OR_MOVE = re.compile(rf"^(\s*)or\s+({REG}),\s*({REG}),\s*({REG})\s*$")
MOVI = re.compile(rf"^(\s*)movi\s+({REG}),\s*(-?\d+)\s*$")
LOAD_STORE = re.compile(rf"^(\s*)(l32i|s32i)\s+({REG}),\s*({REG}),\s*(\d+)\s*$")
ADD = re.compile(rf"^(\s*)add\s+({REG}),\s*({REG}),\s*({REG})\s*$")
ADDI = re.compile(rf"^(\s*)addi\s+({REG}),\s*({REG}),\s*(-?\d+)\s*$")


def narrow(line: str) -> str:
    if m := OR_MOVE.match(line):
        if m.group(3) == m.group(4):
            return f"{m.group(1)}mov.n\t{m.group(2)}, {m.group(3)}"
    elif m := MOVI.match(line):
        if -32 <= int(m.group(3)) <= 95:
            return f"{m.group(1)}movi.n\t{m.group(2)}, {m.group(3)}"
    elif m := LOAD_STORE.match(line):
        offset = int(m.group(5))
        if 0 <= offset <= 60 and offset % 4 == 0:
            return f"{m.group(1)}{m.group(2)}.n\t{m.group(3)}, {m.group(4)}, {offset}"
    elif m := ADD.match(line):
        return f"{m.group(1)}add.n\t{m.group(2)}, {m.group(3)}, {m.group(4)}"
    elif m := ADDI.match(line):
        value = int(m.group(4))
        if value == -1 or 1 <= value <= 15:
            return f"{m.group(1)}addi.n\t{m.group(2)}, {m.group(3)}, {value}"
    return line


def is_literal(stripped: str) -> bool:
    return stripped.startswith(".literal_position") or stripped.startswith(".literal ")


def main() -> int:
    verbatim = 0
    held: list[str] = []
    out = sys.stdout
    keep_unwind = os.environ.get("ABLA_ESP_KEEP_UNWIND") == "1"
    for raw in sys.stdin:
        line = raw.rstrip("\n")
        stripped = line.strip()
        if not keep_unwind and stripped.startswith(".cfi_"):
            continue
        if verbatim == 0 and is_literal(stripped):
            held.append(line)
            continue
        if held:
            # Keep holding across section switches and blank/comment lines;
            # release at the first real line, once the function's section is
            # current.
            if not stripped or stripped.startswith("#") or stripped.startswith(".section"):
                out.write(line + "\n")
                continue
            for literal in held:
                out.write(literal + "\n")
            held.clear()
        if stripped.startswith("#APP") or stripped.startswith(".begin") and "no-transform" in stripped:
            verbatim += 1
        elif stripped.startswith("#NO_APP") or stripped.startswith(".end") and "no-transform" in stripped:
            verbatim = max(0, verbatim - 1)
        elif verbatim == 0 and not stripped.startswith("."):
            # Directives (string data may contain `#`) and lines that do not
            # narrow are copied byte for byte.
            code, sep, comment = line.partition("#")
            narrowed = narrow(code.rstrip())
            if narrowed != code.rstrip():
                line = narrowed + (f" {sep}{comment}" if sep else "")
        out.write(line + "\n")
    for literal in held:
        out.write(literal + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
