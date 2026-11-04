#!/usr/bin/env python3
"""Fixed-seed independent arithmetic oracle for the secret bignum primitives."""
import math
import random
import subprocess
import sys
from pathlib import Path

binary, directory = sys.argv[1:]
out = Path(directory)
rng = random.Random(0xBEEFDA7A)
counts = [(32, 200), (64, 120), (128, 60), (256, 24), (512, 8), (1024, 4), (2048, 2), (4096, 1)]


def run(mode, cases):
    path = out / (mode + ".input")
    wide = mode.endswith("wide")
    path.write_text("".join(f"{m:0{bits//4}x} {n:0{(bits//4)*(2 if wide else 1)}x}\n" for bits, m, n in cases))
    result = subprocess.run([binary, str(path), mode], check=True, text=True, capture_output=True, timeout=180)
    lines = result.stdout.splitlines()
    assert len(lines) == len(cases), (mode, len(lines), len(cases))
    for index, ((bits, m, n), line) in enumerate(zip(cases, lines)):
        rem, quotient, mask = line.split()
        rem, quotient, mask = int(rem, 16), int(quotient, 16), int(mask)
        assert mask in (0, 0xFFFFFFFF), (mode, index, "bad mask", mask)
        if mode == "gcd":
            ok = mask == 0xFFFFFFFF and rem == math.gcd(m, n)
        elif mode == "divsteps":
            g = math.gcd(m, n)
            ok = rem == g and bool(mask) == (g == 1)
            if mask:
                ok &= quotient == pow(n, -1, m)
        elif mode == "inverse":
            valid = m != 0 and math.gcd(m, n) == 1
            ok = bool(mask) == valid and (not valid or quotient == pow(n, -1, m))
        elif mode == "exactwide":
            valid = m != 0 and n % m == 0
            ok = bool(mask) == valid and (not valid or quotient == n // m)
        else:
            ok = bool(mask) == (m != 0)
            if m:
                ok &= rem == n % m
                if mode.startswith("division"):
                    ok &= quotient == n // m
        assert ok, (mode, index, bits, hex(m), hex(n), line)
    print(f"ok   {mode}: {len(cases)} cases")


cases = []
wide = []
odd = []
for bits, count in counts:
    limit = 1 << bits
    edges = [(0, 0), (0, 1), (1, 0), (1, 1), (2, 1), (2, 2),
             (limit - 1, limit - 1), (limit - 2, limit - 1),
             (1 << (bits - 1), 1 << (bits - 2))]
    small = [(a, b) for a in range(16) for b in range(16)] if bits == 32 else []
    pairs = edges + small + [(rng.getrandbits(bits), rng.getrandbits(bits)) for _ in range(count)]
    cases += [(bits, a, b) for a, b in pairs]
    odd += [(bits, a, b) for a, b in pairs if a & 1]
    for a, b in pairs:
        wide.append((bits, a, (b << bits) | rng.getrandbits(bits)))
        if a:
            wide.append((bits, a, a * b))  # Exact, including zero quotient and full-width products.

# Dense limb-width coverage, including all small widths and 17/64/127/128 boundaries.
for words in (*range(1, 9), 12, 16, 17, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 127, 128):
    bits = words * 32
    a, b = rng.getrandbits(bits), rng.getrandbits(bits)
    cases.append((bits, a, b))
    odd.append((bits, a | 1, b))
    wide.append((bits, a, (b << bits) | rng.getrandbits(bits)))
    if a:
        wide.append((bits, a, a * b))

for mode, data in [("divsteps", odd), ("gcd", cases), ("inverse", cases),
                   ("division", cases), ("divisionwide", wide), ("reducewide", wide), ("exactwide", wide)]:
    run(mode, data)
