#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
directory="$project_root/build/structured-type-reflection"
program="$directory/program"
mkdir -p "$directory"

"$compiler" build \
    "$project_root/tests/cases/modules/structured-type-reflection.ab" \
    --no-cache -o "$program"
set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
[[ $status -eq 42 ]]

set +e
"$compiler" build \
    "$project_root/tests/cases/modules/invalid-structured-type-handle.ab" \
    --no-cache -o "$directory/invalid" \
    > "$directory/invalid.out" 2> "$directory/invalid.err"
invalid_status=$?
set -e
[[ $invalid_status -ne 0 ]]

printf '%s\n' \
    'structured type reflection: compound/function/nominal/affine + invalid handle passed'
