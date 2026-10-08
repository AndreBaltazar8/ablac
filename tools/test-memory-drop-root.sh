#!/usr/bin/env bash
# A function's result survives the resource drops that run after it is computed,
# with collections running inside the drop helpers.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/memory-drop-root"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/runtime-memory-drop-root.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "memory drop root: a result outlives the drops after it"
