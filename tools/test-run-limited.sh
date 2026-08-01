#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
runner="$root/tools/run-limited.sh"

limits=$(
    ABLA_MAX_MEMORY_MB=64 \
    ABLA_MAX_SECONDS=3 \
    ABLA_MAX_CPU_SECONDS=2 \
        "$runner" bash -c 'ulimit -v; ulimit -t; ulimit -c'
)
[[ $limits == $'65536\n2\n0' ]]

set +e
ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=3 \
    "$runner" bash -c 'exit 42'
status=$?
set -e
[[ $status -eq 42 ]]

marker="abla-limit-test-$$"
set +e
timeout_output=$(
    ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=1 \
        "$runner" \
        bash -c 'bash -c "sleep 30" "$1-child" & wait' _ "$marker" \
        2>&1
)
status=$?
set -e
[[ $status -eq 124 ]]
[[ $timeout_output == *'stopped after 1 wall-clock second(s)'* ]]
if pgrep -f "$marker-child" >/dev/null; then
    printf '[test-run-limited] descendant process leaked after timeout\n' >&2
    pgrep -af "$marker-child" >&2
    exit 1
fi

set +e
invalid_output=$(ABLA_MAX_MEMORY_MB=unlimited "$runner" true 2>&1)
status=$?
set -e
[[ $status -eq 2 ]]
[[ $invalid_output == *'must be a positive integer'* ]]

printf '%s\n' 'limited runner tests passed'
