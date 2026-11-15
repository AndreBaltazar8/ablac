#!/usr/bin/env bash
# In a module imported `as` an alias, a block-local `val x` shadows the module's top-level `x`
# only to the end of its block: a later read of `x` in the same function names the module's
# (it was left unrewritten, E_SEMANTIC identifier:x, because the function bound `x` somewhere).
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/alias-local-shadow"
output_directory="$project_root/build/alias-local-shadow"
mkdir -p "$output_directory"

"$compiler" build "$cases/main.ab" -o "$output_directory/main"
set +e
"$output_directory/main"
status=$?
set -e
[[ $status -eq 42 ]] || { echo "alias-local-shadow: case $status failed" >&2; exit 1; }
echo "alias-local-shadow: a block-local ends with its block in an aliased module"
