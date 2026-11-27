#!/usr/bin/env bash
# #1139 area 14: the statically linked compiler's strftime (src/static_libc/time.ab) against the host C library's, on generated formats and times:
# the conversions it knows (not the zone's %Z %z), literal text, %%, a % that ends the format (written as it is, and nothing past the NUL read),
# tm_wday and tm_mon out of range (a "?" name), and buffer sizes from 0 up (0 when the result and its NUL do not fit).
# `tools/test-libc-strftime.sh COMPILER [SEED [COUNT]]`.
set -euo pipefail
export LC_ALL=C TZ=UTC
compiler=${1:-build/ablac}
seed=${2:-1}
count=${3:-20000}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
[[ $(uname -s) == Linux ]] || { echo 'libc strftime: Linux only'; exit 0; }
cc=$(command -v cc || command -v clang || command -v gcc || true)
[[ -n $cc ]] || { echo 'libc strftime: no C compiler' >&2; exit 1; }
out=build/libc-strftime
rm -rf "$out"
mkdir -p "$out/libc"
"$cc" -O1 -w tests/cases/libc-strftime/strftime.c -o "$out/strftime"
"$out/strftime" gen "$seed" "$count" > "$out/cases.txt"
"$out/strftime" < "$out/cases.txt" > "$out/c.txt"
# The static libc's modules cannot be imported by an ordinary program as they are (their exported C symbols clash with the runtime's): copies
# without the @export lines.
for file in src/static_libc/*.ab; do sed '/^@export/d' "$file" > "$out/libc/${file##*/}"; done
cp tests/cases/libc-strftime/main.ab "$out/main.ab"
"$compiler" build "$out/main.ab" -o "$out/abla" --no-cache > "$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; echo 'libc strftime: the test program failed to build' >&2; exit 1; }
timeout 600 "$out/abla" < "$out/cases.txt" > "$out/abla.txt"
total=$(wc -l < "$out/cases.txt")
paste -d'\t' "$out/cases.txt" "$out/c.txt" "$out/abla.txt" | awk -F'\t' '$4 != $6 || $5 != $7 { print $1 "\t" $2 "\t" $3 "\thost [" $4 " " $5 "] abla [" $6 " " $7 "]" }' > "$out/differences.txt"
if [[ -s $out/differences.txt ]]; then
    head -20 "$out/differences.txt" >&2
    echo "libc strftime: $total cases, $(wc -l < "$out/differences.txt") differ from the host C library's strftime" >&2
    exit 1
fi
echo "libc strftime: $total cases (seed $seed) agree with the host C library's strftime"
