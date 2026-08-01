#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "$0")/.." && pwd)
output_directory="$project_root/build/generated-virtual-module"
source_file="$project_root/tests/cases/modules/generated-virtual-module.ab"
mkdir -p "$output_directory"

"$compiler" --emit-llvm "$source_file" > "$output_directory/first.ll"
"$compiler" --emit-llvm "$source_file" > "$output_directory/second.ll"
cmp "$output_directory/first.ll" "$output_directory/second.ll"
opt --threads=1 -passes=verify -disable-output "$output_directory/first.ll"
"$compiler" build "$source_file" -o "$output_directory/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]]

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/bootstrap/invalid-generated-virtual-module.ab" \
    > "$output_directory/invalid.ll" 2> "$output_directory/invalid.err"
invalid_status=$?
set -e
[[ $invalid_status -ne 0 ]]
grep -Eq 'type|identifier|function.argument' "$output_directory/invalid.err"

printf '%s\n' 'generated virtual module: bounded deterministic transaction + rollback diagnostic passed'
