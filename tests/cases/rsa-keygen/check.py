#!/usr/bin/env python3
"""Independent PKCS#8 and FIPS-parameter checks on a generated key."""
import math
import sys
from pathlib import Path


def item(data, offset):
    tag = data[offset]
    length = data[offset + 1]
    offset += 2
    if length & 128:
        width = length & 127
        length = int.from_bytes(data[offset:offset + width], 'big')
        offset += width
    end = offset + length
    assert end <= len(data)
    return tag, data[offset:end], end


def children(data):
    offset = 0
    result = []
    while offset < len(data):
        tag, value, offset = item(data, offset)
        result.append((tag, value))
    assert offset == len(data)
    return result


size = int(sys.argv[1])
der = Path(sys.argv[2]).read_bytes()
tag, outer, end = item(der, 0)
assert tag == 0x30 and end == len(der)
fields = children(outer)
assert fields[2][0] == 4
inner_tag, inner, inner_end = item(fields[2][1], 0)
assert inner_tag == 0x30 and inner_end == len(fields[2][1])
parts = children(inner)
assert len(parts) == 9 and all(tag == 2 for tag, _ in parts)
version, n, e, d, p, q, dp, dq, qi = (int.from_bytes(value, 'big') for _, value in parts)
half = size // 2
floor = math.isqrt(1 << (2 * half - 1)) + 1
lam = math.lcm(p - 1, q - 1)
assert version == 0 and n.bit_length() == size and n == p * q and e == 65537
assert p >= floor and q >= floor and p.bit_length() == q.bit_length() == half
assert abs(p - q) > 1 << (half - 100)
assert math.gcd(e, p - 1) == math.gcd(e, q - 1) == 1
assert (1 << half) < d < lam and (e * d) % lam == 1
assert dp == d % (p - 1) and dq == d % (q - 1) and (q * qi) % p == 1
