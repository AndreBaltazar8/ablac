#!/usr/bin/env bash
# A program's Cell under `#` stays a Cell when a closure or a generator keeps
# its binding (the evaluator's capture boxes are a kind of their own), as
# at run time.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/compile-time-cell-capture"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/compile-time-cell-capture.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "compile-time Cell values: identical to run time"
