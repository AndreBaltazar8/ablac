#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
program=$project_root/build/xtensa-interrupt-handler-test
diagnostics=$project_root/build/xtensa-interrupt-handler-test.stderr

"$compiler" build \
    "$project_root/tests/cases/modules/xtensa-interrupt-handler.ab" \
    -o "$program" --fast --no-cache
set +e
"$program" 2>"$diagnostics"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    cat "$diagnostics" >&2
    exit 1
fi

echo 'Xtensa interrupt handler lowering passed'
