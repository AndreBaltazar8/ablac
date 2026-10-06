#!/usr/bin/env bash
# jsonParse limits are per call: large documents parse with raised limits.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/json-limits"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/json-large-limits.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]]
echo "json limits: per call, above the defaults, depth bounded"
