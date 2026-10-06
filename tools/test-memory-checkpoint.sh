#!/usr/bin/env bash
# A memory checkpoint survives a collection that frees the allocation it was
# taken after; the reset frees only what came later.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/memory-checkpoint"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/runtime-memory-checkpoint-collect.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "memory checkpoint: survives a collection, resets only what came after"
