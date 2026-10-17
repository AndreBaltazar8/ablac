#!/usr/bin/env bash
# Fixed-width and nominal scalars at compile time (conversions, wrapping,
# unsigned u64, scalar-receiver methods, f64Text, a `return` inside an
# argument) give what they give at run time.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/compile-time-scalars"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/compile-time-scalars.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "compile-time scalars: identical to run time"
