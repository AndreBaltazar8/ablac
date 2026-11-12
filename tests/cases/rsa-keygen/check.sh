#!/usr/bin/env bash
# Independent PKCS#8 and FIPS-parameter checks on a generated key: the DER
# structure is read by awk and the arithmetic done by bc, neither of which
# shares code with the library that generated the key.
# Usage: check.sh KEY-BITS PKCS8.der
set -euo pipefail
size=$1
der=$2
hex=$(od -An -v -tx1 "$der" | tr -d ' \n' | tr a-f A-F)

# PKCS#8 { version, algorithm, OCTET STRING { RSAPrivateKey SEQUENCE of 9
# INTEGERs } }: print the nine integers as hex, one per line.
integers=$(printf '%s\n' "$hex" | awk '
function fail(message) { print "RSA key check: " message > "/dev/stderr"; bad = 1; exit 1 }
function byte(at) { return index("0123456789ABCDEF", substr(hex, 2 * at + 1, 1)) * 16 - 16 \
                           + index("0123456789ABCDEF", substr(hex, 2 * at + 2, 1)) - 1 }
# Reads the header at byte `at`: sets tag, start (first content byte), end.
function item(at,    len, width, i) {
    tag = byte(at); len = byte(at + 1); at += 2
    if (len >= 128) {
        width = len - 128; len = 0
        for (i = 0; i < width; i++) len = len * 256 + byte(at + i)
        at += width
    }
    start = at; end = at + len
    if (2 * end > total) fail("item overruns the data")
}
{
    hex = $0; total = length(hex)
    item(0)
    if (tag != 48 || 2 * end != total) fail("outer item is not the whole SEQUENCE")
    at = start
    for (field = 0; field < 3; field++) {
        item(at)
        if (field == 2) { if (tag != 4) fail("third field is not an OCTET STRING"); break }
        at = end
    }
    inner_start = start; inner_end = end
    item(inner_start)
    if (tag != 48 || end != inner_end) fail("inner item is not the whole SEQUENCE")
    at = start; limit = end; count = 0
    while (at < limit) {
        item(at)
        if (tag != 2) fail("RSAPrivateKey member is not an INTEGER")
        print substr(hex, 2 * start + 1, 2 * (end - start)); count++
        at = end
        if (count == 9) break
    }
    if (count != 9) fail("RSAPrivateKey does not have 9 INTEGERs")
}')
[[ $(printf '%s\n' "$integers" | wc -l | tr -d ' ') == 9 ]]
results=$({
    echo 'ibase=A'
    echo "size = $size"
    i=0
    for name in version n e d p q dp dq qi; do
        i=$((i + 1))
        printf 'ibase=16\n%s = %s\nibase=A\n' "$name" "$(printf '%s\n' "$integers" | sed -n "${i}p")"
    done
    cat <<'BC'
define g(a, b) { auto t; while (b > 0) { t = a % b; a = b; b = t }; return (a) }
define l(a, b) { return (a / g(a, b) * b) }
define w(x) { auto r; r = 0; while (x > 0) { x /= 2; r += 1 }; return (r) }
define m(x, y) { if (x > y) return (x - y); return (y - x) }
scale = 0
half = size / 2
floor = sqrt(2 ^ (2 * half - 1)) + 1
lam = l(p - 1, q - 1)
"version 0 "; version == 0
"modulus bits "; w(n) == size
"n = p*q "; n == p * q
"e "; e == 65537
"p >= floor "; p >= floor
"q >= floor "; q >= floor
"p bits "; w(p) == half
"q bits "; w(q) == half
"p, q distance "; m(p, q) > 2 ^ (half - 100)
"gcd(e, p-1) "; g(e, p - 1) == 1
"gcd(e, q-1) "; g(e, q - 1) == 1
"d > 2^half "; d > 2 ^ half
"d < lcm "; d < lam
"e*d = 1 mod lcm "; (e * d) % lam == 1
"dp "; dp == d % (p - 1)
"dq "; dq == d % (q - 1)
"qinv "; (q * qi) % p == 1
BC
} | bc)
count=$(printf '%s\n' "$results" | grep -c ' 1$' || true)
if [[ $count != 17 ]] || printf '%s\n' "$results" | grep -q ' 0$'; then
    echo "RSA $size key failed the parameter checks:" >&2
    printf '%s\n' "$results" >&2
    exit 1
fi
