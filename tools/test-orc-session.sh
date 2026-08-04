#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
runner="$project_root/build/orc-session-runner"
first_ir="$project_root/build/orc-session-first.ll"
second_ir="$project_root/build/orc-session-second.ll"

ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=60 \
    "$project_root/tools/run-limited.sh" \
    "$compiler" build "$project_root/src/orc_session_runner.ab" \
    -o "$runner"
"$compiler" --emit-llvm \
    "$project_root/tests/cases/bootstrap/return-41.ab" > "$first_ir"
"$compiler" --emit-llvm \
    "$project_root/tests/cases/bootstrap/block.ab" > "$second_ir"

set +e
ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" \
    "$runner" "$first_ir" "$second_ir"
status=$?
set -e
[[ $status -eq 42 ]]

printf '%s\n' 'persistent ORC session: load 41 -> reclaim -> load 42'
