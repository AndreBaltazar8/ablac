#!/usr/bin/env bash
# A lambda where a void function is expected may end in an assignment, and so may a
# function, method or extension declared `: void`.
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

"$compiler" build \
    "$project_root/tests/cases/modules/function-void-assignment.ab" \
    -o "$output_directory/function" --no-cache
set +e
output=$("$output_directory/function")
status=$?
set -e
[[ $status -eq 42 && $output == "27 11" ]] || { echo "function: status $status, output '$output'"; exit 1; }
echo "void assignment: callbacks and void functions may end in an assignment"
