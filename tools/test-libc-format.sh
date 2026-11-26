#!/usr/bin/env bash
# #1139 area 14: the statically linked compiler's snprintf family (src/static_libc/format.ab) against the host C library's, on generated conversions: flags,
# widths and precisions (literal and `*`, negative ones too), length modifiers, d i u x X o c s p and %%, NULL strings, bytes over 127, and buffer sizes from 0
# to 4096 (the return value and the bytes written). Only conversions whose behaviour C defines are generated. `tools/test-libc-format.sh COMPILER [SEED [COUNT]]`.
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
seed=${2:-1}
count=${3:-20000}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
[[ $(uname -sm) == 'Linux x86_64' ]] || { echo 'libc format: x86-64 Linux only (the va_list is the System V one)'; exit 0; }
cc=$(command -v cc || command -v clang || command -v gcc || true)
[[ -n $cc ]] || { echo 'libc format: no C compiler' >&2; exit 1; }
out=build/libc-format
rm -rf "$out"
mkdir -p "$out"
"$cc" -O1 -w tests/cases/libc-format/format.c -o "$out/format"
"$out/format" gen "$seed" "$count" > "$out/cases.txt"
"$out/format" < "$out/cases.txt" > "$out/c.txt"
# string.ab, stdio.ab and format.ab cannot be imported by an ordinary program (their exported symbols clash with the runtime's): copies without the @export lines.
local_copy() { sed -e '/^@export/d' -e 's|^import "\./string\.ab"|import "./strto.ab"|' -e 's|^import "\./stdio\.ab"|import "./stdio.ab"|' \
    -e '/^import "\.\/\(strto\|stdio\)\.ab"/!s|^import "\./|import "../../src/static_libc/|' "$1"; }
local_copy src/static_libc/string.ab > "$out/strto.ab"
local_copy src/static_libc/stdio.ab > "$out/stdio.ab"
local_copy src/static_libc/format.ab > "$out/format.ab"
cp tests/cases/libc-format/main.ab "$out/main.ab"
"$compiler" build "$out/main.ab" -o "$out/abla" --no-cache > "$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; echo 'libc format: the test program failed to build' >&2; exit 1; }
timeout 600 "$out/abla" < "$out/cases.txt" > "$out/abla.txt"
total=$(wc -l < "$out/cases.txt")
paste -d'\t' "$out/cases.txt" "$out/c.txt" "$out/abla.txt" | awk -F'\t' '$4 != $6 || $5 != $7 { print $1 "\t" $2 "\t" $3 "\thost [" $4 " " $5 "] abla [" $6 " " $7 "]" }' > "$out/differences.txt"
if [[ -s $out/differences.txt ]]; then
    head -20 "$out/differences.txt" >&2
    echo "libc format: $total cases, $(wc -l < "$out/differences.txt") differ from the host C library's snprintf" >&2
    exit 1
fi
echo "libc format: $total cases (seed $seed) agree with the host C library's snprintf"
