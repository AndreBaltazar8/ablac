#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
program=$("$project_root/tools/compiler-api-test-program.sh" "$compiler")
set +e
ABLA_COMPILER_API_CASE=symbols ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=60 \
    "$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1

printf '%s\n' 'native linkage: declaration insertion and body edits remain stable'
