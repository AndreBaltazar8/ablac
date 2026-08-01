#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
program="$project_root/build/stable-native-symbols-test"

"$compiler" build \
    "$project_root/tests/cases/modules/stable-native-symbols.ab" \
    -o "$program" --fast --no-cache
set +e
ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=60 \
    "$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
[[ $status -eq 42 ]]

printf '%s\n' 'native linkage: declaration insertion and body edits remain stable'
