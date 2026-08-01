#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
program="$project_root/build/text-unicode"

"$compiler" build "$project_root/tests/cases/modules/text-unicode.ab" \
    -o "$program" --fast --no-cache
set +e
"$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
[[ $status -eq 42 ]]

printf '%s\n' 'UTF-8 text: compile/runtime validation + scalar indexing/slicing passed'
