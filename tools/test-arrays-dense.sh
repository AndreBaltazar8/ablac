#!/usr/bin/env bash
# Arrays of numbers and bools are stored densely and box on demand.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/arrays-dense"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/arrays-dense.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]]
echo "dense arrays: numbers and bools in 8-byte words, boxed on demand"
