#!/usr/bin/env bash
# #184 (G3 option A, docs/design/aarch64-linux-c-boundary.md): on an AArch64 Linux machine, a program that brings a C library
# links the machine's glibc, as on x86-64. The nine programs tools/libc-free-programs-allowlist.txt lists as nobuild-a64 (they
# do not build for aarch64-linux from x86-64) are built --fast with the native compiler and run, each with the status its
# x86-64 build exits with. Those with a C boundary (LLVM in the process, dlsym, libm's sin) must name a NEEDED library; the
# one without (compile-time-recursion-deep) and a hello world must stay libc-free. Elsewhere it skips; CI runs it on
# ubuntu-24.04-arm (ci.yml job aarch64-c-boundary), with the static AArch64 compiler built for that commit.
# Usage: tools/test-aarch64-c-boundary.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
if [[ $(uname -s) != Linux || $(uname -m) != aarch64 ]]; then
    echo 'aarch64 c boundary: skipped (not an AArch64 Linux machine)'
    exit 0
fi
out=build/aarch64-c-boundary
rm -rf "$out"
mkdir -p "$out"
fail() { echo "aarch64 c boundary: $1" >&2; exit 1; }
# program, the status it exits with, and whether it links a C library (libc) or none (static)
programs='bootstrap-llvm 0 libc
compile-time-recursion-deep 0 static
conformance-ir-cache 42 libc
import-alias-externs 42 libc
lowered-ir-cache 42 libc
native-function-address 42 libc
stable-native-symbols 42 libc
unsafe-boundary 42 libc
xtensa-interrupt-handler 42 libc'
[[ $(grep -c '^nobuild-a64 ' tools/libc-free-programs-allowlist.txt) == "$(wc -l <<< "$programs")" ]] ||
    fail 'the nobuild-a64 lines of tools/libc-free-programs-allowlist.txt and this list differ'
printf 'import "abla/io"\nfun main { println("hello") }\n' > "$out/hello.ab"
programs+=$'\n'"hello 0 static"
built=0
while read -r name want linkage; do
    source=tests/cases/modules/$name.ab
    [[ $name != hello ]] || source=$out/hello.ab
    grep -qx "nobuild-a64 $name" tools/libc-free-programs-allowlist.txt || [[ $name == hello ]] ||
        fail "$name is not a nobuild-a64 line"
    "$compiler" build "$source" -o "$out/$name" --fast --no-cache > "$out/$name.log" 2>&1 ||
        { tail -20 "$out/$name.log" >&2; fail "$name does not build natively"; }
    needed=$(readelf -d "$out/$name" | grep -c '(NEEDED)' || true)
    if [[ $linkage == libc ]]; then
        ((needed > 0)) || fail "$name brings a C library but links none"
        readelf -d "$out/$name" | grep 'NEEDED.*libc\.so' > /dev/null || fail "$name does not link glibc"
    else
        ((needed == 0)) || fail "$name brings no C library but names $needed: $(readelf -d "$out/$name" | grep NEEDED)"
    fi
    status=0
    "$out/$name" > "$out/$name.out" 2>&1 || status=$?
    [[ $status == "$want" ]] || { tail -20 "$out/$name.out" >&2; fail "$name exited $status, not $want"; }
    built=$((built + 1))
done <<< "$programs"
echo "aarch64 c boundary: $built programs built natively and ran; the C-boundary ones link glibc, the others none"
