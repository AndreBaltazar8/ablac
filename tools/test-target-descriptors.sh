#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
directory="$project_root/build/target-descriptors-test"
mkdir -p "$directory"

"$compiler" build "$project_root/tests/cases/bootstrap/block.ab" \
    --fast --no-cache -o "$directory/hosted"
set +e
"$project_root/tools/run-limited.sh" "$directory/hosted"
hosted_status=$?
set -e
[[ $hosted_status -eq 42 ]]

set +e
"$compiler" build "$project_root/tests/cases/bootstrap/block.ab" \
    --fast --no-cache --target imaginary-none \
    -o "$directory/invalid" \
    >"$directory/invalid.out" 2>"$directory/invalid.err"
invalid_status=$?
set -e
[[ $invalid_status -eq 2 ]]
grep -q "unsupported target 'imaginary-none'" "$directory/invalid.err"
[[ ! -e "$directory/invalid" ]]

"$compiler" build \
    "$project_root/tests/cases/target-descriptors/generic-object-build.ab" \
    --fast --no-cache -o "$directory/generic-driver"
set +e
"$project_root/tools/run-limited.sh" "$directory/generic-driver"
generic_status=$?
set -e
[[ $generic_status -eq 43 ]]
llvm-readelf -h "$directory/riscv64.o" > "$directory/riscv64.header"
grep -q 'RISC-V' "$directory/riscv64.header"
grep -q '"llvmTriple":"riscv64-unknown-elf"' \
    "$directory/riscv64.o.abi.json"

"$compiler" build "$project_root/tests/cases/bootstrap/block.ab" \
    --fast --no-cache \
    --target-triple riscv64-unknown-elf --object-format elf \
    -o "$directory/raw-riscv64.o"
llvm-readelf -h "$directory/raw-riscv64.o" \
    > "$directory/raw-riscv64.header"
grep -q 'RISC-V' "$directory/raw-riscv64.header"
grep -q '"llvmTriple":"riscv64-unknown-elf"' \
    "$directory/raw-riscv64.o.abi.json"

set +e
"$compiler" build "$project_root/tests/cases/bootstrap/block.ab" \
    --fast --no-cache \
    --target-triple riscv64-unknown-elf --object-format elf \
    --emit executable -o "$directory/raw-executable" \
    >"$directory/raw-executable.out" \
    2>"$directory/raw-executable.err"
raw_executable_status=$?
set -e
[[ $raw_executable_status -eq 2 ]]
grep -q 'emits only object or static-library artifacts' \
    "$directory/raw-executable.err"
[[ ! -e "$directory/raw-executable" ]]

printf '%s\n' \
    'target descriptors: hosted, extension-defined and raw LLVM objects, and deterministic unsupported-target diagnostics passed'
