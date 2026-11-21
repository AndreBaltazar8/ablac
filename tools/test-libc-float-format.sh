#!/usr/bin/env bash
# #806 step C: the statically linked compiler's printf formats a double (%f %F %e %E %g %G %a %A, flags # and precisions 0 to 19) digit for digit as the
# host C library does (src/static_libc/floatfmt.ab): subnormals, halfway cases, large exponents, random bit patterns, inf and nan. LLVM prints doubles
# through snprintf (--emit-llvm text, assembly), so a different digit would make the static compiler's output differ from the ordinary one's.
# Usage: tools/test-libc-float-format.sh [compiler]
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
[[ $(uname -s) == Linux ]] || { echo 'libc float format: Linux only'; exit 0; }
cc=$(command -v cc || command -v clang || command -v gcc || true)
[[ -n $cc ]] || { echo 'libc float format: no C compiler' >&2; exit 1; }
out=build/libc-float-format
rm -rf "$out"
mkdir -p "$out"
"$cc" -O1 -w tests/cases/libc-float-format/format.c -o "$out/format" -lm
"$out/format" gen > "$out/cases.txt"
"$out/format" < "$out/cases.txt" > "$out/c.txt"
"$compiler" build tests/cases/libc-float-format/main.ab -o "$out/abla" --no-cache > "$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; echo 'libc float format: the test program failed to build' >&2; exit 1; }
"$out/abla" < "$out/cases.txt" > "$out/abla.txt"
count=$(wc -l < "$out/cases.txt")
if ! cmp -s "$out/c.txt" "$out/abla.txt"; then
    paste -d'\t' "$out/cases.txt" "$out/c.txt" "$out/abla.txt" | awk -F'\t' '(""$2) != (""$3) { print "case [" $1 "] host [" $2 "] abla [" $3 "]" }' | head -20 >&2
    echo "libc float format: $count cases, they differ from the host C library's printf" >&2
    exit 1
fi
echo "libc float format: $count cases, identical to the host C library's printf"
# strtof: the text rounded once to a float (halfway cases between two floats, subnormals, the overflow edge), as the host's strtof reads it.
"$out/format" strtof-gen > "$out/strtof-cases.txt"
"$out/format" strtof < "$out/strtof-cases.txt" > "$out/strtof-c.txt"
"$compiler" build tests/cases/libc-float-format/strtof.ab -o "$out/strtof" --no-cache > "$out/strtof-build.log" 2>&1 ||
    { cat "$out/strtof-build.log" >&2; echo 'libc float format: the strtof test program failed to build' >&2; exit 1; }
"$out/strtof" < "$out/strtof-cases.txt" > "$out/strtof-abla.txt"
strtof_count=$(wc -l < "$out/strtof-cases.txt")
if ! cmp -s "$out/strtof-c.txt" "$out/strtof-abla.txt"; then
    paste -d'\t' "$out/strtof-cases.txt" "$out/strtof-c.txt" "$out/strtof-abla.txt" |
        awk -F'\t' '(""$2) != (""$3) { print "text [" $1 "] host bits " $2 " abla bits " $3 }' | head -20 >&2
    echo "libc float format: $strtof_count strtof cases, they differ from the host C library's strtof" >&2
    exit 1
fi
echo "libc float format: $strtof_count strtof cases, identical to the host C library's strtof"
