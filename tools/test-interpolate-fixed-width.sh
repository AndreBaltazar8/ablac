#!/usr/bin/env bash
# Fixed-width integers (i8 to u64) interpolate as their decimal values.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/interpolate-fixed-width"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/interpolate-fixed-width.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "interpolate fixed width: i8 to u64"
