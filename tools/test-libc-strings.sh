#!/usr/bin/env bash
# #1139 area 14: the statically linked compiler's string functions (src/static_libc/string.ab, ctypestr.ab) against the host C library's, on
# generated short strings with bytes past 127: strlen, strcmp, strncmp, strcasecmp, strncasecmp, strcoll, strchr, strrchr, memchr, memrchr,
# strnlen, strspn, strcspn, strpbrk, strstr, strncat and strndup, the counts from 0 to past the end and SIZE_MAX (no bound, not none).
# `tools/test-libc-strings.sh COMPILER [SEED [COUNT]]`.
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
seed=${2:-1}
count=${3:-20000}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
[[ $(uname -s) == Linux ]] || { echo 'libc strings: Linux only'; exit 0; }
cc=$(command -v cc || command -v clang || command -v gcc || true)
[[ -n $cc ]] || { echo 'libc strings: no C compiler' >&2; exit 1; }
out=build/libc-strings
rm -rf "$out"
mkdir -p "$out/libc"
"$cc" -O1 -w tests/cases/libc-strings/strings.c -o "$out/strings"
"$out/strings" gen "$seed" "$count" > "$out/cases.txt"
"$out/strings" < "$out/cases.txt" > "$out/c.txt"
# The static libc's modules cannot be imported by an ordinary program as they are (their exported C symbols clash with the runtime's): copies
# without the @export lines.
for file in src/static_libc/*.ab; do sed '/^@export/d' "$file" > "$out/libc/${file##*/}"; done
cp tests/cases/libc-strings/main.ab "$out/main.ab"
"$compiler" build "$out/main.ab" -o "$out/abla" --no-cache > "$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; echo 'libc strings: the test program failed to build' >&2; exit 1; }
timeout 600 "$out/abla" < "$out/cases.txt" > "$out/abla.txt"
total=$(wc -l < "$out/cases.txt")
paste -d'\t' "$out/cases.txt" "$out/c.txt" "$out/abla.txt" | awk -F'\t' '$6 != $7 { print $1 "\t" $2 "\t" $3 "\t" $4 "\t" $5 "\thost [" $6 "] abla [" $7 "]" }' > "$out/differences.txt"
if [[ -s $out/differences.txt ]]; then
    head -20 "$out/differences.txt" >&2
    echo "libc strings: $total cases, $(wc -l < "$out/differences.txt") differ from the host C library's functions" >&2
    exit 1
fi
echo "libc strings: $total cases (seed $seed) agree with the host C library's functions"
