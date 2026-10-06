#!/usr/bin/env bash
# `own` and `region` are keywords only where they introduce an owned
# parameter or a region block.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/contextual-keywords"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/contextual-keywords.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "contextual keywords: own and region as names"
