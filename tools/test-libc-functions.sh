#!/usr/bin/env bash
# The functions of the statically linked compiler's C library that had been aborting stubs (#806 step C, src/static_libc: math2.ab, iconv.ab,
# spawn.ab, wcsftime.ab, stackprot.ab, dlfind.ab), each called as the ordinary Abla function it is from a program of its own in tests/cases
# (libc-math-functions, libc-iconv, libc-spawn, libc-wcsftime exit 42; libc-stack-chk-fail ends by SIGABRT after writing its message to
# standard error). Linux only. The same code is what the static compiler links (tools/test-static-compiler.sh).
# Usage: tools/test-libc-functions.sh [compiler]
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'libc functions: Linux only'; exit 0; }
out=build/libc-functions
rm -rf "$out"
mkdir -p "$out"
for name in math-functions iconv spawn wcsftime stack-chk-fail; do
    "$compiler" build "tests/cases/libc-$name/main.ab" -o "$out/$name" --no-cache > "$out/$name.build.log" 2>&1 ||
        { echo "libc functions: libc-$name did not build" >&2; tail -20 "$out/$name.build.log" >&2; exit 1; }
done
for name in math-functions iconv spawn wcsftime; do
    code=0
    "$out/$name" > "$out/$name.out" 2>&1 < /dev/null || code=$?
    [[ $code == 42 ]] || { echo "libc functions: libc-$name exited $code" >&2; cat "$out/$name.out" >&2; exit 1; }
done
code=0
{ "$out/stack-chk-fail" > "$out/stack-chk-fail.out" 2> "$out/stack-chk-fail.err" < /dev/null; } 2> /dev/null || code=$?
[[ $code == 134 ]] || { echo "libc functions: __stack_chk_fail ended with status $code, not SIGABRT (134)" >&2; exit 1; }
[[ $(cat "$out/stack-chk-fail.err") == '*** stack smashing detected ***: terminated' ]] ||
    { echo "libc functions: __stack_chk_fail wrote [$(cat "$out/stack-chk-fail.err")]" >&2; exit 1; }
echo 'libc functions: math, iconv, posix_spawn, wcsftime and __stack_chk_fail agree'
