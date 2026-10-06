#!/usr/bin/env bash
# Floats at compile time give the bits the program computes at run time.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/compile-time-floats"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/compile-time-floats.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-compile-time-f32.ab" \
    > "$output_directory/invalid.ll" 2> "$output_directory/invalid.err"
invalid=$?
set -e
[[ $status -eq 42 && $invalid -ne 0 ]] || exit 1
grep -q 'compile.result:f32' "$output_directory/invalid.err"
echo "compile-time floats: bit-identical to run time"
