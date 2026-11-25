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
if [[ -s $out/new-differences.txt ]]; then
    head -20 "$out/new-differences.txt" >&2
    echo "libc parse: $total cases, $(wc -l < "$out/new-differences.txt") differ from the host C library's answers and are not in $known" >&2
    exit 1
fi
echo "libc parse: $total cases (seed $seed), $(wc -l < "$out/differences.txt") known differences, none else"
