#!/usr/bin/env bash
# `+` and `+=` concatenate strings, at run time and at compile time.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/string-plus"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/string-plus.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-string-plus-number.ab" \
    > "$output_directory/invalid.ll" 2> "$output_directory/invalid.err"
invalid=$?
set -e
[[ $status -eq 42 && $invalid -ne 0 ]] || exit 1
grep -q 'arithmetic.type' "$output_directory/invalid.err"
echo "string plus: concatenation at run time and compile time"
