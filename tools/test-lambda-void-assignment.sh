#!/usr/bin/env bash
# A lambda where a void function is expected may end in an assignment.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/lambda-void-assignment"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/lambda-void-assignment.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "lambda void assignment: callbacks may end in an assignment"
