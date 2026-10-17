#!/usr/bin/env bash
# A program whose only array read is in a generated drop function (an array
# of FnOnce closures over resources) links and drops each resource once.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/resource-drop-link"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/resource-lambda-drop.ab" \
    -o "$output_directory/resource-lambda-drop" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/resource-lambda-drop"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1
echo "resource drop link: drop functions keep the runtime they call"
