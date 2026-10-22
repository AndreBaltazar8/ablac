#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
runner="$root/tools/run-limited.sh"

expected_virtual=65536
if [[ $(uname -s) == Darwin ]]; then
    # Darwin has no virtual-memory ulimit. The runner deliberately leaves the
    # caller's existing value unchanged there.
    expected_virtual=$(ulimit -S -v)
fi

limits=$(
    ABLA_MAX_MEMORY_MB=64 \
    ABLA_MAX_SECONDS=3 \
    ABLA_MAX_CPU_SECONDS=2 \
        "$runner" bash -c 'ulimit -v; ulimit -t; ulimit -c'
)
[[ $limits == "$expected_virtual"$'\n2\n0' ]] || exit 1

set +e
ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=3 \
    "$runner" bash -c 'exit 42'
status=$?
set -e
[[ $status -eq 42 ]] || exit 1

nested_memory=$(
    unset ABLA_MAX_MEMORY_MB
    "$runner" bash -c '
        export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
        exec "$1" printenv ABLA_MAX_MEMORY_MB
    ' _ "$runner"
)
[[ $nested_memory == 2048 ]] || exit 1

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
[[ $status -eq 124 ]] || exit 1
[[ $timeout_output == *'time limit (1 s, ABLA_MAX_SECONDS) reached: killed after 1 wall-clock second(s)'* ]] || exit 1
if pgrep -f "$marker-child" >/dev/null; then
    printf '[test-run-limited] descendant process leaked after timeout\n' >&2
    pgrep -af "$marker-child" >&2
    exit 1
fi

# The CPU limit stops a busy command (SIGXCPU) and says which limit it was.
set +e
cpu_output=$(
    ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=60 ABLA_MAX_CPU_SECONDS=1 \
        "$runner" perl -e '1 while 1' 2>&1
)
status=$?
set -e
[[ $status -eq 152 ]] || exit 1
[[ $cpu_output == *'CPU time limit (1 s, ABLA_MAX_CPU_SECONDS) reached'* ]] || exit 1

set +e
invalid_output=$(ABLA_MAX_MEMORY_MB=unlimited "$runner" true 2>&1)
status=$?
set -e
[[ $status -eq 2 ]] || exit 1
[[ $invalid_output == *'must be a positive integer'* ]] || exit 1

printf '%s\n' 'limited runner tests passed'
