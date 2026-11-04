#!/usr/bin/env python3
"""Emit a file-free AArch64 numerical test with Python-computed answers."""
import math
import sys
from pathlib import Path

out = Path(sys.argv[1])
lines = ['import "abla/crypto/bignum"', 'import "abla/ct"', '']
checks = []
for case, words in enumerate((1, 3, 17, 64, 128)):
    bits = words * 32
    modulus = (1 << (bits - 1)) + 1000 + case
    if case % 2:
        modulus |= 1
    else:
        modulus &= ~1
    value = 65537
    while math.gcd(modulus, value) != 1:
        modulus += 2
    expected_inverse = pow(value, -1, modulus)
    numerator = modulus * 0x1234567 + 17
    exact = modulus * 0x1234567
    expected_quotient = 0x1234567
    name = f"kat{case}"
    checks.append(name)
    lines += [f'trusted fun {name}(): bool {{', f'    val w = {words}',
              '    val m = bnAllocate(w)', '    val v = bnAllocate(w)',
              '    val gcd = bnAllocate(w)', '    val inverse = bnAllocate(w)',
              '    val work = bnAllocate(13 * w + 9 * (w + 1))',
              '    val numerator = bnAllocate(2 * w)', '    val quotient = bnAllocate(2 * w)',
              '    val remainder = bnAllocate(w)', '    val scratch = bnAllocate(w)', '    var ok = true']

    def write(address, integer, width):
        for i in range(width):
            limb = (integer >> (32 * i)) & 0xFFFFFFFF
            if limb:
                lines.append(f'    bnStore({address} + {4*i}, secretU32(u32({limb})))')

    def expect(address, integer, width):
        for i in range(width):
            limb = (integer >> (32 * i)) & 0xFFFFFFFF
            lines.append(f'    if (bnLoad({address} + {4*i}).declassify() != u32({limb})) ok = false')

    write('m', modulus, words)
    write('v', value, words)
    lines += ['    if (bnSecretGcdBody(gcd, m, v, w, work).declassify() == u32(0)) ok = false']
    expect('gcd', 1, words)
    lines += ['    if (bnSecretInverseBody(inverse, m, v, w, work).declassify() == u32(0)) ok = false']
    expect('inverse', expected_inverse, words)
    write('numerator', numerator, 2 * words)
    lines += ['    if (bnSecretDivModBody(quotient, remainder, numerator, 2*w, m, w, scratch).declassify() == u32(0)) ok = false']
    expect('quotient', expected_quotient, 2 * words)
    expect('remainder', 17, words)
    lines += ['    if (bnSecretExactDivBody(quotient, numerator, 2*w, m, w, remainder, scratch).declassify() != u32(0)) ok = false',
              '    bnClear(numerator, 2*w)']
    write('numerator', exact, 2 * words)
    lines += ['    if (bnSecretExactDivBody(quotient, numerator, 2*w, m, w, remainder, scratch).declassify() == u32(0)) ok = false']
    expect('quotient', expected_quotient, 2 * words)
    lines += ['    if (bnSecretDivModBody(numerator, remainder, numerator, 2*w, m, w, scratch).declassify() != u32(0)) ok = false',
              '    bnRelease(m, w)', '    bnRelease(v, w)', '    bnRelease(gcd, w)', '    bnRelease(inverse, w)',
              '    bnRelease(work, 13*w + 9*(w+1))', '    bnRelease(numerator, 2*w)', '    bnRelease(quotient, 2*w)',
              '    bnRelease(remainder, w)', '    bnRelease(scratch, w)', '    ok', '}', '']
lines += ['@export("simd_checks")', 'fun aarch64Oracle(): int {']
for i, name in enumerate(checks, 1):
    lines.append(f'    if (!{name}()) return {i}')
lines += ['    0', '}', '']
out.write_text('\n'.join(lines))
