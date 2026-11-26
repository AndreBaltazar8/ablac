#!/usr/bin/env bash
# #1139 area 4: the statically linked compiler's number parsers (src/static_libc: strtod in time.ab, strtol, strtoll, strtoul and strtoull in string.ab) read untrusted text (the
# compiler's input: source, IR, assembly, command lines) and must read it as the host C library does: the value, where the parse stopped (endptr) and errno, for a
# generated mix of spaces, signs, prefixes, digits at the edges of 64 bits, decimal points, exponents, hex floats, inf and nan, and bytes outside ASCII.
# `tools/test-libc-parse.sh COMPILER [SEED [COUNT]]`; known differences are in tools/libc-parse-known.txt ("kind base hextext" lines the Abla side may answer differently).
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
seed=${2:-1}
count=${3:-20000}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
[[ $(uname -s) == Linux ]] || { echo 'libc parse: Linux only'; exit 0; }
cc=$(command -v cc || command -v clang || command -v gcc || true)
[[ -n $cc ]] || { echo 'libc parse: no C compiler' >&2; exit 1; }
out=build/libc-parse
rm -rf "$out"
mkdir -p "$out"
"$cc" -O1 -w tests/cases/libc-parse/parse.c -o "$out/parse"
"$out/parse" gen "$seed" "$count" > "$out/cases.txt"
# The decimal midpoints between neighbouring doubles and floats with the deciding digit at 767 to 810 significant digits (tools/fuzz/f64-boundary.mjs).
if command -v node > /dev/null; then node tools/fuzz/f64-boundary.mjs libc "$seed" 12 >> "$out/cases.txt"; fi
"$out/parse" < "$out/cases.txt" > "$out/c.txt"
# string.ab cannot be imported by an ordinary program (its exported memcpy and friends clash with the runtime's own): the test builds from a copy without the @export lines.
sed -e '/^@export/d' -e 's|^import "\./|import "../../src/static_libc/|' src/static_libc/string.ab > "$out/strto.ab"
cp tests/cases/libc-parse/main.ab "$out/main.ab"
"$compiler" build "$out/main.ab" -o "$out/abla" --no-cache > "$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; echo 'libc parse: the test program failed to build' >&2; exit 1; }
timeout 600 "$out/abla" < "$out/cases.txt" > "$out/abla.txt"
total=$(wc -l < "$out/cases.txt")
paste -d'\t' "$out/cases.txt" "$out/c.txt" "$out/abla.txt" | awk -F'\t' '$2 != $3 { print $1 "\thost [" $2 "] abla [" $3 "]" }' > "$out/differences.txt"
known=tools/libc-parse-known.txt
awk -F'\t' 'FILENAME == ARGV[1] { if ($0 !~ /^#/ && NF) skip[$1] = 1; next } !($1 in skip) { print }' "$known" "$out/differences.txt" > "$out/new-differences.txt"
# One class of difference is known and not listed line by line: glibc reports ERANGE when the exact value is below the smallest normal number but rounds up to it
# (tininess before rounding; the midpoint between the largest subnormal and the smallest normal does), the static libc only for a subnormal or zero result. The value and
# the end offset are the same, and only ERANGE on the host's side with the smallest normal double (4503599627370496) or float (8388608) is let through.
awk -F'\t' '{
    n = split($2, t, /[][ ]+/)
    if (n >= 8 && t[1] == "host" && t[5] == "abla" && t[4] == "34" && t[8] == "0" && t[2] == t[6] && t[3] == t[7] &&
        (t[2] == "4503599627370496" || t[2] == "8388608")) next
    print
}' "$out/new-differences.txt" > "$out/new-differences.filtered" && mv "$out/new-differences.filtered" "$out/new-differences.txt"
if [[ -s $out/new-differences.txt ]]; then
    head -20 "$out/new-differences.txt" >&2
    echo "libc parse: $total cases, $(wc -l < "$out/new-differences.txt") differ from the host C library's answers and are not in $known" >&2
    exit 1
fi
echo "libc parse: $total cases (seed $seed), $(wc -l < "$out/differences.txt") known differences, none else"
# The cost of a megabyte of digits (and of zeros, a long fraction, a long exponent, a long hex float) stays linear: each shape, read by strtod and by strtof, takes at most about 10 times a 100,000-byte control from the same run (a fixed time bound flaked on a loaded runner).
cost=$(printf 'T 0 00\n' | timeout 300 "$out/abla")
[[ $cost == 'cost ok' ]] || { echo "libc parse: a megabyte-long number is slow: $cost" >&2; exit 1; }
echo "libc parse: a megabyte of digits, zeros, fraction, exponent and hex digits reads in time linear in its length"
