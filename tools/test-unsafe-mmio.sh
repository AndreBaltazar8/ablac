#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
output=build/tests/unsafe-mmio.ll
mkdir -p "$(dirname "$output")"
"$compiler" --emit-llvm tests/cases/modules/unsafe-mmio.ab > "$output"

for instruction in \
    'load volatile i8' \
    'load volatile i16' \
    'load volatile i32' \
    'load volatile i64' \
    'store volatile i8' \
    'store volatile i16' \
    'store volatile i32' \
    'store volatile i64'
do
    if ! grep -Fq "$instruction" "$output"; then
        echo "missing LLVM MMIO instruction: $instruction" >&2
        exit 1
    fi
done

echo "unsafe MMIO LLVM lowering passed"
