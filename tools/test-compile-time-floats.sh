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
set -e
[[ $status -eq 42 ]] || exit 1

# An f32 result lifts as the same f32 bits.
"$compiler" build \
    "$project_root/tests/cases/modules/compile-time-f32-result.ab" \
    -o "$output_directory/single" --no-cache
set +e
"$output_directory/single"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1

# A 20000-entry table evaluates whole (it stopped at 100000 steps).
"$compiler" build "$project_root/tests/cases/modules/compile-time-tables.ab" \
    -o "$output_directory/tables" --no-cache
set +e
"$output_directory/tables"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "compile-time floats: bit-identical to run time"
