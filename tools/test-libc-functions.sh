#!/usr/bin/env bash
# The functions of the statically linked compiler's C library that had been aborting stubs (#806 step C, src/static_libc: math2.ab, iconv.ab,
# spawn.ab, wcsftime.ab, stackprot.ab, dlfind.ab), each called as the ordinary Abla function it is from a program of its own in tests/cases
# (libc-math-functions, libc-iconv, libc-spawn, libc-wcsftime exit 42; libc-stack-chk-fail ends by SIGABRT after writing its message to
# standard error). Linux only. The same code is what the static compiler links (tools/test-static-compiler.sh).
# Usage: tools/test-libc-functions.sh [compiler]
set -euo pipefail
export LC_ALL=C
ulimit -c 0   # the abort test must not leave a core file in the tree
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
source "$root/tools/aarch64-test-runner.sh"
[[ $(uname -s) == Linux ]] || { echo 'libc functions: Linux only'; exit 0; }
out=build/libc-functions
rm -rf "$out"
mkdir -p "$out"
for name in math-functions correct-rounding iconv spawn wcsftime stack-chk-fail; do
    "$compiler" build "tests/cases/libc-$name/main.ab" -o "$out/$name" --no-cache > "$out/$name.build.log" 2>&1 ||
        { echo "libc functions: libc-$name did not build" >&2; tail -20 "$out/$name.build.log" >&2; exit 1; }
done
for name in math-functions correct-rounding iconv spawn wcsftime; do
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
# The same modules for AArch64 Linux (#806 step C, the static compiler's second target): the programs that do not run another program are
# built with --target aarch64-linux and run under qemu-aarch64 (posix_spawn's test starts the host's /bin/sh, which the guest cannot).
if aarch64_runner_available; then
    for name in math-functions correct-rounding iconv wcsftime stack-chk-fail; do
        "$compiler" build "tests/cases/libc-$name/main.ab" -o "$out/$name.aarch64" --target aarch64-linux --no-cache > "$out/$name.aarch64.build.log" 2>&1 ||
            { echo "libc functions: libc-$name did not build for aarch64-linux" >&2; tail -20 "$out/$name.aarch64.build.log" >&2; exit 1; }
    done
    for name in math-functions correct-rounding iconv wcsftime; do
        code=0
        aarch64_run -- "$out/$name.aarch64" > "$out/$name.aarch64.out" 2>&1 < /dev/null || code=$?
        [[ $code == 42 ]] || { echo "libc functions: libc-$name exited $code on AArch64" >&2; cat "$out/$name.aarch64.out" >&2; exit 1; }
    done
    code=0
    { aarch64_run -- "$out/stack-chk-fail.aarch64" > /dev/null 2> "$out/stack-chk-fail.aarch64.err" < /dev/null; } 2> /dev/null || code=$?
    [[ $code == 134 ]] || { echo "libc functions: AArch64 __stack_chk_fail ended with status $code" >&2; exit 1; }
    [[ $(head -n 1 "$out/stack-chk-fail.aarch64.err") == '*** stack smashing detected ***: terminated' ]] ||
        { echo "libc functions: AArch64 __stack_chk_fail wrote [$(head -n 1 "$out/stack-chk-fail.aarch64.err")]" >&2; exit 1; }
    echo 'libc functions: the same four agree for aarch64-linux under qemu'
fi
