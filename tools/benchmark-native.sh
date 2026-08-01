#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/bootstrap/ablac-llvm}
output=build/benchmark/ablac-native
mkdir -p build/benchmark

start_ns=$(date +%s%N)
ABLA_MAX_MEMORY_MB=2048 ABLA_MAX_SECONDS=120 tools/run-limited.sh \
    nix-shell --run "$compiler build bootstrap/compiler/main.ab -o $output"
end_ns=$(date +%s%N)
elapsed_ms=$(((end_ns - start_ns) / 1000000))

ABLA_MAX_MEMORY_MB=512 ABLA_MAX_SECONDS=120 tools/run-limited.sh \
    "$output" --emit-llvm bootstrap/compiler/main.ab \
    > build/benchmark/ablac-native.fixed.ll
cmp build/bootstrap/ablac-llvm.ll build/benchmark/ablac-native.fixed.ll

bytes=$(stat -c %s "$output")
printf 'LLVM-native full self-build: %s ms\n' "$elapsed_ms"
printf 'LLVM-native compiler size: %s bytes\n' "$bytes"
printf 'LLVM-native fixed point: byte-identical IR\n'
