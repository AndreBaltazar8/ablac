#!/usr/bin/env bash
set -euo pipefail

memory_mb=${ABLA_MAX_MEMORY_MB:-2048}
wall_seconds=${ABLA_MAX_SECONDS:-600}
cpu_seconds=${ABLA_MAX_CPU_SECONDS:-$wall_seconds}
kill_grace_seconds=${ABLA_KILL_GRACE_SECONDS:-5}

usage() {
    printf '%s\n' \
        'usage: run-limited.sh COMMAND [ARGUMENT ...]' \
        'environment: ABLA_MAX_MEMORY_MB, ABLA_MAX_SECONDS,' \
        '             ABLA_MAX_CPU_SECONDS, ABLA_KILL_GRACE_SECONDS' >&2
    exit 2
}

require_positive_integer() {
    local name=$1
    local value=$2
    if [[ ! $value =~ ^[1-9][0-9]*$ ]]; then
        printf '[abla-limit] %s must be a positive integer, got %q\n' \
            "$name" "$value" >&2
        exit 2
    fi
}

(( $# > 0 )) || usage
require_positive_integer ABLA_MAX_MEMORY_MB "$memory_mb"
require_positive_integer ABLA_MAX_SECONDS "$wall_seconds"
require_positive_integer ABLA_MAX_CPU_SECONDS "$cpu_seconds"
require_positive_integer ABLA_KILL_GRACE_SECONDS "$kill_grace_seconds"

if (( memory_mb > 8796093022207 )); then
    printf '[abla-limit] ABLA_MAX_MEMORY_MB is too large: %s\n' "$memory_mb" >&2
    exit 2
fi
memory_bytes=$((memory_mb * 1024 * 1024))
# Nested compiler launchers must inherit this cap instead of choosing a larger
# default and trying to raise the hard limit installed by this runner.
export ABLA_MAX_MEMORY_MB=$memory_mb

# Runs the bounded command as a background job that keeps standard input (a
# job's is /dev/null otherwise) and forwards TERM, INT and HUP to it: stopping
# this script stops what it runs, which the limiter passes to the command's
# process group.
bounded() {
    "$@" <&0 &
    local job=$!
    trap 'kill -TERM "$job" 2>/dev/null' TERM
    trap 'kill -INT "$job" 2>/dev/null' INT
    trap 'kill -HUP "$job" 2>/dev/null' HUP
    status=0
    wait "$job" || status=$?
    # A forwarded signal interrupts the wait; the job's own status follows.
    while kill -0 "$job" 2>/dev/null; do
        wait "$job" && status=0 || status=$?
    done
    trap - TERM INT HUP
}

started=$SECONDS
# macOS has no setpriv/timeout/prlimit: tools/run-limited-darwin.sh supervises the payload group
# and this shell's lifetime. ABLA_RUN_LIMITED_SUPERVISOR=shell selects it on any host (the tests
# exercise it on Linux).
if [[ $OSTYPE == darwin* || ${ABLA_RUN_LIMITED_SUPERVISOR:-} == shell ]]; then
    ulimit -S -c 0
    ulimit -S -t "$cpu_seconds"
    runner_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    set +e
    # Job control gives the supervisor a process group of its own, so a kill of this
    # shell's group leaves it to stop the payload group.
    set -m
    bounded "$runner_directory/run-limited-darwin.sh" \
        "$$" "$wall_seconds" "$kill_grace_seconds" "$@"
    set +m
    set -e
else
    # Leave one CPU second between SIGXCPU and the hard SIGKILL fallback so
    # the normal exit status identifies the CPU limit (152).
    set +e
    limited=(timeout \
        --signal=TERM \
        --kill-after="${kill_grace_seconds}s" \
        "${wall_seconds}s" \
        prlimit \
            --as="${memory_bytes}:${memory_bytes}" \
            --cpu="${cpu_seconds}:$((cpu_seconds + 1))" \
            --core=0:0 \
            -- \
            "$@")
    if command -v setpriv >/dev/null 2>&1; then
        # The timeout owns a separate process group. If this shell dies, ask
        # timeout to forward TERM to that group and apply its KILL grace. The
        # PPID check closes the race where the shell dies before setpriv arms
        # the parent-death signal, so no payload starts after reparenting.
        limited=(setpriv --pdeathsig TERM bash -c '
            expected_parent=$1
            shift
            [[ $PPID == "$expected_parent" ]] || exit 125
            exec "$@"
        ' _ "$$" "${limited[@]}")
    fi
    # Minimal Linux installations without setpriv keep the previous timeout
    # behavior; their bounded process group cannot follow an uncatchable kill
    # of this shell.
    bounded "${limited[@]}"
    set -e
fi

# Killed at the wall-clock limit: 124 (the limiter's TERM), 142 (an alarm) or,
# on Linux, 137 when the command outlived TERM and the grace period. Whatever
# the signal, a command stopped at the limit exits 124 and says so.
if [[ $status == 124 || $status == 142 ||
      ($status == 137 && $((SECONDS - started)) -ge $wall_seconds) ]]; then
    status=124
fi

case $status in
    124)
        printf '[abla-limit] time limit (%s s, ABLA_MAX_SECONDS) reached: killed after %s wall-clock second(s)\n' \
            "$wall_seconds" "$wall_seconds" >&2
        ;;
    137)
        printf '[abla-limit] process was killed; address-space limit is %s MiB\n' \
            "$memory_mb" >&2
        ;;
    134)
        printf '[abla-limit] process aborted; address-space limit is %s MiB\n' \
            "$memory_mb" >&2
        ;;
    139)
        printf '[abla-limit] process crashed; address-space limit is %s MiB\n' \
            "$memory_mb" >&2
        ;;
    152)
        printf '[abla-limit] CPU time limit (%s s, ABLA_MAX_CPU_SECONDS) reached: killed after %s CPU second(s)\n' \
            "$cpu_seconds" "$cpu_seconds" >&2
        ;;
esac

exit "$status"
