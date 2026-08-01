#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
library="$project_root/build/.abla-jit-host.so"
rm -f "$library"
set +e
ABLA_MAX_MEMORY_MB=512 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$compiler" run \
    "$project_root/tests/cases/bootstrap/block.ab"
status=$?
set -e
[[ $status -eq 42 ]]
[[ ! -e $library ]]

set +e
ABLA_MAX_MEMORY_MB=768 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$compiler" run \
    "$project_root/tests/cases/modules/filesystem.ab"
status=$?
set -e
[[ $status -eq 42 ]]
[[ ! -e $library ]]

set +e
ABLA_MAX_MEMORY_MB=768 ABLA_MAX_SECONDS=30 \
    "$project_root/tools/run-limited.sh" "$compiler" run \
    "$project_root/tests/cases/modules/host-runtime.ab"
status=$?
set -e
[[ $status -eq 42 ]]
[[ -s $library ]]
printf '%s\n' \
    'JIT host selection: pure/portable-raw runs skipped and explicit host capability loaded the C adapter'
