#!/usr/bin/env bash
# The macOS shell supervisor (tools/run-limited-darwin.sh) behind tools/run-limited.sh:
# caller death, signals, the deadline, descendant cleanup, the start-up race and every
# exit code. It has no OS check, so Linux runs the same cases (ABLA_RUN_LIMITED_SUPERVISOR
# selects it there); macOS CI runs them through the launcher's own macOS branch.
# Needs only POSIX tools and bash 3.2: no setsid (job control gives a process group),
# no /proc, no GNU options.
# Usage: darwin-parent-death.sh RUNNER   (tools/run-limited.sh)
set -u

runner=$(cd "$(dirname "$1")" && pwd)/$(basename "$1")
supervisor=$(dirname "$runner")/run-limited-darwin.sh
export ABLA_RUN_LIMITED_SUPERVISOR=shell
tmp=$(mktemp -d "${TMPDIR:-/tmp}/abla-darwin-limit.XXXXXX")
cleanup_pids=()
cleanup() {
    local pid
    for pid in ${cleanup_pids[@]+"${cleanup_pids[@]}"}; do kill -KILL "$pid" 2>/dev/null; kill -KILL -- "-$pid" 2>/dev/null; done
    rm -rf "$tmp"
}
trap cleanup EXIT
fail() { echo "Darwin runner: $*" >&2; exit 1; }

alive() {
    local state
    state=$(ps -o stat= -p "$1" 2>/dev/null)
    [[ -n $state && $state != Z* && $state != ' Z'* ]]
}
stopped() {
    local state
    state=$(ps -o stat= -p "$1" 2>/dev/null)
    state=${state# }
    [[ $state == T* ]]
}
gone() { local pid; for pid in "$@"; do ! alive "$pid" || return 1; done; }
# No process of the group is executing.
group_empty() { ! ps -axo pgid=,stat= | awk -v group="$1" '$1 == group && $2 !~ /^Z/ { found = 1 } END { exit !found }'; }
nonempty() { [[ -s $1 ]]; }
wait_for() { # SECONDS LABEL COMMAND...
    local seconds=$1 label=$2 tries=0
    shift 2
    while ! "$@"; do
        tries=$((tries + 1))
        [[ $tries -lt $((seconds * 100)) ]] || fail "timed out waiting for $label"
        sleep 0.01
    done
}

# The payload: a group leader and one descendant (same group), the leader recording
# "payload child supervisor". `stubborn` ignores TERM in both. The leader execs sleep, so
# its pid stays the sleeper's.
cat > "$tmp/worker.sh" <<'WORKER'
marker=$1
if [ "$2" = stubborn ]; then trap '' TERM; fi
sleep 60 &
printf '%s %s %s\n' "$$" "$!" "$PPID" > "$marker.tmp" && mv "$marker.tmp" "$marker"
exec sleep 60
WORKER

# run_tree KIND MODE: KIND is group (kill the runner's whole group), term, hup, int or timeout.
run_tree() {
    local kind=$1 mode=$2 name=$1-$2 marker seconds=60 expected status=0
    marker=$tmp/$name
    [[ $kind != timeout ]] || seconds=1
    set -m
    ABLA_MAX_SECONDS=$seconds ABLA_KILL_GRACE_SECONDS=1 \
        "$runner" sh "$tmp/worker.sh" "$marker" "$mode" > /dev/null 2> "$tmp/$name.log" < /dev/null &
    local proc=$!
    set +m
    cleanup_pids+=("$proc")
    wait_for 10 "payload and descendant readiness" nonempty "$marker"
    local payload child supervisor_pid group
    read -r payload child supervisor_pid < "$marker"
    cleanup_pids+=("$payload" "$child" "$supervisor_pid")
    group=$(ps -o pgid= -p "$payload" | tr -d ' ')
    [[ $group != "$proc" ]] || fail "$name: payload shares the caller's group"
    [[ $group == "$payload" ]] || fail "$name: payload is not its group's leader"
    [[ $(ps -o pgid= -p "$child" | tr -d ' ') == "$group" ]] || fail "$name: descendant escaped the payload group"
    [[ $(ps -o pgid= -p "$supervisor_pid" | tr -d ' ') != "$proc" ]] || fail "$name: supervisor shares the caller's group"
    case $kind in
    group) kill -KILL -- "-$proc"; expected=137 ;;
    term) kill -TERM "$proc"; expected=143 ;;
    hup) kill -HUP "$proc"; expected=129 ;;
    int) kill -INT "$proc"; expected=130 ;;
    timeout) expected=124 ;;
    esac
    wait_for 10 "$name runner to exit" gone "$proc"
    { wait "$proc"; } 2>/dev/null || status=$?
    # A killed caller cannot report a status; the others pass through the launcher's.
    [[ $status == "$expected" ]] || fail "$name: exit $status, expected $expected: $(cat "$tmp/$name.log")"
    wait_for 5 "$name payload group cleanup" gone "$payload" "$child"
    wait_for 5 "$name supervisor exit" gone "$supervisor_pid"
    group_empty "$group" || fail "$name: a process of the payload group survived"
    echo "Darwin runner: $name payload and descendant stopped"
}

# The payload's status, a signal's 128+N and a missing command pass through the supervisor.
status_of() { # EXPECTED LABEL COMMAND...
    local expected=$1 label=$2 status=0
    shift 2
    "$runner" "$@" > /dev/null 2>&1 < /dev/null || status=$?
    [[ $status == "$expected" ]] || fail "$label: exit $status, expected $expected"
}
status_of 42 "payload status" sh -c 'exit 42'
status_of 137 "payload killed by a signal" sh -c 'kill -KILL $$'
status_of 127 "command not found" /nonexistent-abla-command
status_of 0 "payload success" sh -c 'exit 0'
echo "Darwin runner: payload status, signal status and missing command pass through"

# The supervisor refuses to start without its caller: a pid that is not its parent.
for fake in 999999 1; do
    status=0
    "$supervisor" "$fake" 5 1 sh -c 'echo ran > "$1"' _ "$tmp/refused-ran" > /dev/null 2>&1 || status=$?
    [[ $status == 125 ]] || fail "a caller that is not the parent ($fake): exit $status, expected 125"
done
[[ ! -e $tmp/refused-ran ]] || fail "the payload started for a caller that is not the parent"

run_tree group normal
run_tree group stubborn
run_tree term normal
run_tree hup normal
run_tree int normal
run_tree timeout stubborn

# Stop the supervisor's interpreter before it can check its caller. Killing only the
# runner leaves the stopped process alive, so resuming it exercises the check, rather
# than merely killing the unarmed helper with a group.
# The real bash, found before the shim is on PATH (the shim would find itself).
real_bash=$(command -v bash)
private_bin=$tmp/bin
mkdir "$private_bin"
cat > "$private_bin/bash" <<SHIM
#!$real_bash
case \${1:-} in
*run-limited-darwin.sh) printf '%s\\n' "\$\$" > "\$ABLA_TEST_SHIM_READY"; kill -STOP "\$\$" ;;
esac
exec "\$ABLA_TEST_REAL_BASH" "\$@"
SHIM
chmod 755 "$private_bin/bash"
set -m
PATH=$private_bin:$PATH ABLA_TEST_SHIM_READY=$tmp/prearm-ready ABLA_TEST_REAL_BASH=$real_bash \
    "$runner" sh -c 'echo ran > "$1"' _ "$tmp/payload-ran" > /dev/null 2>&1 < /dev/null &
proc=$!
set +m
cleanup_pids+=("$proc")
wait_for 10 "unarmed supervisor" nonempty "$tmp/prearm-ready"
trampoline=$(cat "$tmp/prearm-ready")
cleanup_pids+=("$trampoline")
wait_for 10 "supervisor trampoline stopped" stopped "$trampoline"
kill -KILL "$proc"
{ wait "$proc"; } 2>/dev/null
kill -CONT "$trampoline"
wait_for 10 "reparented supervisor exit" gone "$trampoline"
[[ ! -e $tmp/payload-ran ]] || fail "payload started after the launcher died before the supervisor's check"
echo "Darwin parent death: pre-start race fails closed"

# No interpreter beyond POSIX tools is needed: PATH holds only what the scripts call.
minimal=$tmp/minimal
mkdir "$minimal"
for tool in bash dirname ps awk sleep; do ln -s "$(command -v "$tool")" "$minimal/$tool"; done
status=0
PATH=$minimal "$runner" "$(type -P true)" > /dev/null 2>&1 || status=$?
[[ $status == 0 ]] || fail "the runner needs more than bash, dirname, ps, awk and sleep: exit $status"
echo "Darwin runner: no Python needed"
