#!/usr/bin/env bash
# A kept string retains a flat buffer, not the pieces it was built from: short
# concatenations are flat, and flattening a rope drops its children.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/string-retention"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/string-retention.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "string retention: flat short strings, flattened ropes drop their pieces"
