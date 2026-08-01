#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "$0")/.." && pwd)
output_directory="$project_root/build/canonical-module-paths"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/canonical-module-paths.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]]

printf '%s\n' 'canonical module paths: dot/dot-dot/repeated-separator aliases deduplicated'
