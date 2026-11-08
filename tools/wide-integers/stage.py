#!/usr/bin/env python3
"""stage.py TYPE FROM TO: copies tests/cases/wide-integers into TO for one of uint256, int256, uint128 and
int128: `__T__` becomes the type, `__BYTES__` its size, and a line starting @u, @s, @256 or @128 is kept
(without the tag) only for an unsigned, a signed, a 256-bit or a 128-bit type. `.in` files lose the suffix."""
import os
import shutil
import sys

kind, source, target = sys.argv[1:4]
signed = kind.startswith("int")
bits = int(kind[-3:])
maxdec = {"uint256": 2 ** 256 - 1, "int256": 2 ** 255 - 1, "uint128": 2 ** 128 - 1, "int128": 2 ** 127 - 1}[kind]
words = ("u32(0), u32(0), u32(0), u32(0), u32(0), u32(0), u32(1), u32(2)" if bits == 256
         else "u32(0), u32(0), u32(1), u32(2)")
edge = ("u32(4294967295), u32(0), u32(305419896), u32(1), u32(2147483648), u32(7), u32(65536), u32(9)" if bits == 256
        else "u32(2147483648), u32(7), u32(65536), u32(9)")
other = {"uint256": "int256", "int256": "uint128", "uint128": "int128", "int128": "uint256"}[kind]
keep = {"@u": not signed, "@s": signed, "@256": bits == 256, "@128": bits == 128}
os.makedirs(target, exist_ok=True)
for name in sorted(os.listdir(source)):
    path = os.path.join(source, name)
    text = open(path).read() if not name.endswith(".mjs") else None
    if text is None:
        shutil.copy(path, os.path.join(target, name))
        continue
    out = []
    for line in text.split("\n"):
        tag = line.split(" ", 1)[0] if line.startswith("@") else ""
        head = line.split(" ", 1)[0]
        for t in keep:
            if line.startswith(t + " ") or line.startswith(t + "\t"):
                break
        else:
            t = ""
        if t:
            if not keep[t]:
                continue
            line = line[len(t):]
        out.append(line)
    text = ("\n".join(out).replace("__T__", kind).replace("__BYTES__", str(bits // 8)).replace("__WORDS__", words)
            .replace("__BITS__", str(bits)).replace("__OTHER__", other)
            .replace("__EDGEWORDS__", edge).replace("__MAXDECIMAL__", '"%d"' % maxdec)
            .replace("__MINDECIMAL__", '"%d"' % (maxdec + 1)))
    open(os.path.join(target, name[:-3] if name.endswith(".in") else name), "w").write(text)
