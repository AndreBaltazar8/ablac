#!/usr/bin/env bash
# A local or field shadows a top-level binding of its name, across modules
# (the standard library's included): reads, assignments, compile-time globals
# and threads.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/field-shadowing"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/field-shadowing/main.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || { echo "field shadowing: expected 42, got $status" >&2; exit 1; }
echo "field shadowing: fields shadow same-named globals across modules"
