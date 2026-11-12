#!/usr/bin/env bash
# Exercise the Linux limiter's process tree, including its startup race.
# Usage: parent-death.sh RUNNER
set -euo pipefail

runner=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
setpriv=$(command -v setpriv || true)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/abla-limiter-test.XXXXXX")
cleanup_pids=()
cleanup() {
    for pid in ${cleanup_pids[@]+"${cleanup_pids[@]}"}; do kill -KILL "$pid" 2>/dev/null || true; done
    rm -rf "$tmp"
}
trap cleanup EXIT

fail() { echo "limited runner: $*" >&2; exit 1; }

# True while the process exists and is not a zombie.
alive() {
    local stat
    stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    [[ ${stat##*) } != Z* ]]
}
stopped() {
    local stat
    stat=$(cat "/proc/$1/stat" 2>/dev/null) || return 1
    [[ ${stat##*) } == T* ]]
}
# wait_for SECONDS LABEL COMMAND...: poll until the command succeeds.
wait_for() {
    local seconds=$1 label=$2 tries=0
    shift 2
    while ! "$@"; do
        tries=$((tries + 1))
        [[ $tries -lt $((seconds * 100)) ]] || fail "timed out waiting for $label"
        sleep 0.01
    done
}
nonempty() { [[ -s $1 ]]; }
gone() { local pid; for pid in "$@"; do ! alive "$pid" || return 1; done; }

# The payload: a parent that starts one child, both recording their pid; with
# `stubborn` both ignore SIGTERM. The parent execs sleep, so its pid is the
# sleeper's.
cat > "$tmp/worker.sh" <<'WORKER'
root=$1
if [ "$2" = stubborn ]; then trap '' TERM; fi
sh -c 'echo $$ > "$1/child.tmp" && mv "$1/child.tmp" "$1/child" && exec sleep 60' sh "$root" &
while [ ! -s "$root/child" ]; do sleep 0.005; done
echo $$ > "$root/parent.tmp" && mv "$root/parent.tmp" "$root/parent"
exec sleep 60
WORKER

run_tree() {
    local mode=$1 stubborn=${2:-} case_dir name seconds expected
    name=$mode${stubborn:+-stubborn}
    case_dir=$tmp/$name
    mkdir "$case_dir"
    seconds=30
    [[ $mode != timeout ]] || seconds=3
    ABLA_MAX_SECONDS=$seconds ABLA_KILL_GRACE_SECONDS=1 \
        setsid "$runner" sh "$tmp/worker.sh" "$case_dir" "${stubborn:-normal}" \
        > /dev/null 2>&1 < /dev/null &
    local proc=$!
    cleanup_pids+=("$proc")
    wait_for 10 "payload startup" nonempty "$case_dir/parent"
    local parent child supervisor
    parent=$(cat "$case_dir/parent")
    child=$(cat "$case_dir/child")
    cleanup_pids+=("$parent" "$child")
    supervisor=$(ps -o pgid= -p "$parent" | tr -d ' ')
    cleanup_pids+=("$supervisor")
    [[ $supervisor != "$proc" ]] || fail "timeout did not create its own process group"
    case $mode in
    group) kill -KILL -- "-$proc" ;;
    term) kill -TERM "$proc" ;;
    esac
    wait_for 8 "$mode runner to exit" gone "$proc"
    local status=0
    { wait "$proc" || status=$?; } 2>/dev/null
    case $mode in group) expected=137 ;; term) expected=143 ;; timeout) expected=124 ;; esac
    [[ $status == "$expected" ]] || fail "$name: exit $status, expected $expected"
    wait_for 10 "$mode supervisor and descendants to exit" gone "$parent" "$child" "$supervisor"
}

fallback() {
    local private_bin=$tmp/fallback-bin status=0 errors
    mkdir "$private_bin"
    for name in bash timeout prlimit; do ln -s "$(command -v "$name")" "$private_bin/$name"; done
    errors=$(PATH=$private_bin ABLA_MAX_SECONDS=3 "$runner" /bin/sh -c 'exit 42' 2>&1 >/dev/null) || status=$?
    [[ $status == 42 ]] || fail "missing setpriv fallback: $status: $errors"
    [[ -z $errors ]] || fail "missing setpriv emitted an error: $errors"
}

startup_race() {
    local case_dir=$tmp/startup
    mkdir -p "$case_dir/bin"
    cat > "$case_dir/bin/setpriv" <<SHIM
#!$(command -v bash)
printf '%s\\n' "\$\$" > "\$ABLA_TEST_SHIM_READY"
kill -STOP "\$\$"
exec "\$ABLA_TEST_REAL_SETPRIV" "\$@"
SHIM
    chmod 755 "$case_dir/bin/setpriv"
    PATH=$case_dir/bin:$PATH ABLA_TEST_SHIM_READY=$case_dir/ready \
        ABLA_TEST_REAL_SETPRIV=$setpriv ABLA_MAX_SECONDS=30 \
        setsid "$runner" /bin/sh -c 'echo ran > "$1"' _ "$case_dir/payload-ran" \
        > /dev/null 2>&1 < /dev/null &
    local proc=$!
    cleanup_pids+=("$proc")
    # printf writes the pid and its newline at once.
    wait_for 10 "unarmed setpriv shim" nonempty "$case_dir/ready"
    local shim_pid
    shim_pid=$(cat "$case_dir/ready")
    cleanup_pids+=("$shim_pid")
    wait_for 10 "setpriv shim to stop" stopped "$shim_pid"
    kill -KILL "$proc"
    wait "$proc" 2>/dev/null || true
    kill -CONT "$shim_pid"
    wait_for 10 "reparented trampoline to exit" gone "$shim_pid"
    [[ ! -e $case_dir/payload-ran ]] || fail "payload started after its launcher died"
}

fallback
if [[ -n $setpriv ]]; then
    run_tree group
    run_tree group stubborn
    run_tree term
    run_tree timeout
    run_tree timeout stubborn
    startup_race
else
    echo "setpriv unavailable: verified fallback; parent-death cases skipped"
fi
echo "limited runner: parent death, startup race, descendant cleanup and fallback passed"
