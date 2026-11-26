#!/usr/bin/env bash
# The stack protector's canary of libc-free executables (#1139 area 14): on x86-64 Linux the thread block's word at fs:0x28 (tests/cases/stack-canary/tls.ab),
# on AArch64 and RISC-V Linux the global __stack_chk_guard (global.ab, run under qemu), which code built with -fstack-protector reads: LLVM, lld and
# libstdc++ in the static compiler. Each is set from the kernel's AT_RANDOM bytes with the low byte cleared: two runs must print different values, each
# with a low byte of 0. (The AArch64 and RISC-V guard was one constant for every process.) Usage: tools/test-stack-canary.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/stack-canary
rm -rf "$out"
mkdir -p "$out"
check() {
    local label=$1 first=$2 second=$3
    [[ $first == 'canary low=0 rest='* && $second == 'canary low=0 rest='* ]] ||
        { echo "stack canary ($label): the low byte is not 0: '$first' '$second'" >&2; exit 1; }
    [[ $first != "$second" ]] || { echo "stack canary ($label): two runs have the same canary: '$first'" >&2; exit 1; }
    echo "ok   $label: two runs, different canaries, low byte 0"
}
"$compiler" build tests/cases/stack-canary/tls.ab -o "$out/tls" --no-cache > "$out/tls.log" 2>&1 || { cat "$out/tls.log" >&2; exit 1; }
check x86-64 "$("$out/tls")" "$("$out/tls")"
for entry in aarch64-linux:qemu-aarch64 riscv64-linux:qemu-riscv64; do
    target=${entry%%:*} emulator=${entry#*:}
    if ! command -v "$emulator" > /dev/null; then echo "skip $target: no $emulator"; continue; fi
    "$compiler" build tests/cases/stack-canary/global.ab --target "$target" -o "$out/global-$target" --no-cache > "$out/global-$target.log" 2>&1 ||
        { cat "$out/global-$target.log" >&2; exit 1; }
    check "$target" "$("$emulator" "$out/global-$target")" "$("$emulator" "$out/global-$target")"
done
