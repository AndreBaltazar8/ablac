#!/usr/bin/env bash
# abla/text's string helpers (startsWith, split, textJoin, trim, replace,
# uppercase, padStart, ...) at run time and at compile time.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/string-helpers"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/string-helpers.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "string helpers: run time and compile time"
