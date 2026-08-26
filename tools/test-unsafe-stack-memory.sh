#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
output=build/tests/unsafe-stack-memory.ll
binary=build/tests/unsafe-stack-memory
mkdir -p "$(dirname "$output")"
"$compiler" --emit-llvm tests/cases/modules/unsafe-stack-memory.ab > "$output"

grep -Eq 'alloca i8, i64 (8|%[^, ]+)' "$output"
grep -Fq 'store i16' "$output"
grep -Fq 'store i32' "$output"
grep -Fq 'load i16' "$output"
grep -Fq 'load i32' "$output"
grep -Fq '@llvm.memset' "$output"
if grep -Fq 'ret i64 %unsafe.stack.address' "$output"; then
    echo 'stack allocation escaped through a helper frame' >&2
    exit 1
fi
if grep -Fq '@__ablaRuntimeAllocateLayout' "$output"; then
    echo 'stack storage unexpectedly calls the runtime allocator' >&2
    exit 1
fi

"$compiler" build tests/cases/modules/unsafe-stack-memory.ab \
    -o "$binary" --no-cache
set +e
tools/run-limited.sh "$binary"
status=$?
set -e
if [[ $status -ne 35 ]]; then
    printf 'stack memory fixture returned %d, expected 35\n' "$status" >&2
    exit 1
fi

echo "unsafe stack memory caller lifetime and LLVM lowering passed"
