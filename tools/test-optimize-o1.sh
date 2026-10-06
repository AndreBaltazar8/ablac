#!/usr/bin/env bash
# `ablac build --o1`: the middle profile builds a working program.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/optimize-o1"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/string-helpers.ab" \
    -o "$output_directory/program" --o1 --no-cache
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "optimize o1: the middle profile builds and runs"
