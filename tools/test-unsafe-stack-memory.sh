#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
output=build/tests/unsafe-stack-memory.ll
mkdir -p "$(dirname "$output")"
"$compiler" --emit-llvm tests/cases/modules/unsafe-stack-memory.ab > "$output"

grep -Eq 'alloca i8, i64 (8|%[^, ]+)' "$output"
grep -Fq 'store i16' "$output"
grep -Fq 'store i32' "$output"
grep -Fq 'load i16' "$output"
grep -Fq 'load i32' "$output"
grep -Fq '@llvm.memset' "$output"
if grep -Fq '@__ablaRuntimeAllocateLayout' "$output"; then
    echo 'stack storage unexpectedly calls the runtime allocator' >&2
    exit 1
fi

echo "unsafe stack memory LLVM lowering passed"
