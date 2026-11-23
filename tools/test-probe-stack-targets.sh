#!/usr/bin/env bash
# Stack probes ("probe-stack"="inline-asm", see tools/test-stack-guard.sh) belong to the hosted Linux and macOS targets, whose threads' stacks have a
# guard page: the freestanding and embedded targets (Xtensa, bare-metal ARM and RISC-V) have none and their backends take no such probe (the
# Xtensa interrupt-handler lowering failed with it), WebAssembly has its own stack and Windows its own probe. This builds a small program to
# an object for each target with the LLVM text kept (ABLA_KEEP_LLVM_TEXT=1) and counts the attribute in the text.
# Usage: tools/test-probe-stack-targets.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/probe-stack-targets"
rm -rf "${out:?}"
mkdir -p "$out"
printf 'fun main: int { 0 }\n' > "$out/main.ab"
fail() { echo "probe-stack-targets: $1" >&2; exit 1; }

# count <name> <build arguments...>: the number of probe-stack lines in the program's LLVM text for the target.
count() {
    local name=$1; shift
    ABLA_KEEP_LLVM_TEXT=1 "$compiler" build "$out/main.ab" "$@" --emit object -o "$out/$name.o" --no-cache --fast > "$out/$name.log" 2>&1 \
        || fail "$name: the build failed: $(head -c 300 "$out/$name.log")"
    [[ -s $out/$name.o.ll ]] || fail "$name: no LLVM text was kept"
    grep -c 'probe-stack' "$out/$name.o.ll" || true
}

for target in aarch64-linux riscv64-linux; do
    n=$(count "$target" --target "$target")
    ((n > 0)) || fail "$target: a hosted Linux target has no stack probes"
done
for triple in xtensa-esp32-elf thumbv7em-none-eabi riscv32-unknown-elf; do
    n=$(count "$triple" --target-triple "$triple" --object-format elf)
    ((n == 0)) || fail "$triple: a freestanding target carries $n probe-stack attributes"
done
n=$(count wasm32-wasi --target wasm32-wasi)
((n == 0)) || fail "wasm32-wasi carries $n probe-stack attributes"
echo "probe-stack-targets: hosted Linux targets are probed; Xtensa, bare-metal ARM and RISC-V, and Wasm are not"
