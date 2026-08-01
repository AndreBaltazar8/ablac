#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
directory="$project_root/build/target-descriptors-test"
mkdir -p "$directory"

"$compiler" build "$project_root/tests/cases/bootstrap/block.ab" \
    --fast --no-cache --target x86_64-linux \
    -o "$directory/hosted"
set +e
"$project_root/tools/run-limited.sh" "$directory/hosted"
hosted_status=$?
set -e
[[ $hosted_status -eq 42 ]]

set +e
"$compiler" build "$project_root/tests/cases/bootstrap/block.ab" \
    --fast --no-cache --target imaginary-none \
    -o "$directory/invalid" \
    >"$directory/invalid.out" 2>"$directory/invalid.err"
invalid_status=$?
set -e
[[ $invalid_status -eq 2 ]]
grep -q "unsupported target 'imaginary-none'" "$directory/invalid.err"
[[ ! -e "$directory/invalid" ]]

printf '%s\n' \
    'target descriptors: explicit hosted target + deterministic unsupported-target diagnostic passed'
