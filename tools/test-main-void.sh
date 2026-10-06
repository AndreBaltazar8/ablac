#!/usr/bin/env bash
# A `void` main exits 0 after it returns.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/main-void"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/main-void.ab" \
    -o "$output_directory/program" --no-cache
set +e
output=$("$output_directory/program")
status=$?
set -e
[[ $status -eq 0 && $output == "void main" ]] || exit 1
echo "main void: exits 0"
