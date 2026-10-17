#!/usr/bin/env bash
# Resource locals run drop() at the end of their scope (an inner block, then the
# function, latest declared first), whatever the length of their type's name.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/resource-scope-drops"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/resource-short-name-drop.ab" \
    -o "$output_directory/program" --no-cache
output=$("$output_directory/program")
expected=$'inner 3\ndrop File 3\nwork 2 4\ndrop Files 4\ndrop Doc 2\ndrop A 1\ndone'
[[ $output == "$expected" ]] || { echo "unexpected output:"; echo "$output"; exit 1; }
echo "resource scope drops: every local's drop runs, short type names too"
