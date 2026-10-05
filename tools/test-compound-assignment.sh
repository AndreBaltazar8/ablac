#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_root=$project_root/build/compound-assignment-test

mkdir -p "$output_root"
"$compiler" build \
    "$project_root/tests/cases/modules/compound-assignment.ab" \
    -o "$output_root/compound-assignment" --no-cache
set +e
"$output_root/compound-assignment"
status=$?
set -e
test "$status" -eq 42

set +e
"$compiler" build \
    "$project_root/tests/cases/modules/compound-assignment-call.ab" \
    -o "$output_root/compound-assignment-call" --no-cache > "$output_root/call.log" 2>&1
status=$?
set -e
test "$status" -ne 0
grep -q 'E_PARSE_COMPOUND_ASSIGNMENT_TARGET' "$output_root/call.log"
echo "compound assignment: locals, fields, indexes, operator functions, call-free targets passed"
