#!/usr/bin/env bash
# Darwin development runner: supervise a payload group and its caller's lifetime.
#
#   run-limited-darwin.sh PARENT SECONDS GRACE COMMAND [ARG ...]
#
# PARENT is the pid of the caller (tools/run-limited.sh) that started this script as its
# job. The caller starts this script with job control, so it runs in a group of its own:
# a kill of the caller's group does not take the supervisor with it. The payload runs in a
# group of its own as well. The supervisor polls (one sleep per 50 ms tick, nothing else):
# the caller's liveness, TERM/INT/HUP, the deadline and the payload's exit. Then:
#
#   payload exits          its status (128+N when a signal ended it)
#   caller gone            125   TERM to the payload group, KILL after GRACE seconds
#   TERM, INT or HUP       128+N the signal goes to the payload group, KILL after GRACE
#   SECONDS elapsed        124   TERM to the payload group, KILL after GRACE
#   cannot start payload   127
#   caller gone before the payload starts: 125, nothing started
#
# Bash 3.2 (macOS): no associative arrays, no `wait -n`, no sub-second SECONDS.
set -u

if (($# < 4)); then
    echo "usage: run-limited-darwin.sh PARENT SECONDS GRACE COMMAND [ARG ...]" >&2
    exit 2
fi
parent=$1
seconds=$2
grace=$3
shift 3

# The caller must be our parent right now (a caller that died before this script even
# started has left us reparented), and its start time identifies it from here on.
[[ $PPID == "$parent" ]] || exit 125
caller_start=$(ps -o lstart= -p "$parent" 2>/dev/null) || exit 125
[[ -n $caller_start ]] || exit 125

caller_gone() {
    kill -0 "$parent" 2>/dev/null || return 0
    return 1
}
# The slower check, against the caller's pid being reused: its start time must be the same.
caller_replaced() {
    [[ $(ps -o lstart= -p "$parent" 2>/dev/null) == "$caller_start" ]] || return 0
    return 1
}

# Group members that are not zombies.
live_members() {
    ps -axo pgid=,stat= 2>/dev/null | awk -v group="$1" '$1 == group && $2 !~ /^Z/ { found = 1 } END { exit !found }'
}
# signal_group GROUP SIGNAL. XNU's killpg returns EPERM when every member is a zombie;
# that is ignored only after ps confirms nothing in the group is executing. A permission
# failure with live members stays visible.
signal_group() {
    local message
    if message=$(kill -s "$2" -- "-$1" 2>&1); then return 0; fi
    case $message in
        *'No such process'*) return 0 ;;
        *'not permitted'*) live_members "$1" || return 0 ;;
    esac
    printf '[abla-limit] cannot signal the payload group: %s\n' "$message" >&2
    return 1
}

pending=0
note_signal() { ((pending == 0)) && pending=$1; return 0; }
trap 'note_signal 15' TERM
trap 'note_signal 2' INT
trap 'note_signal 1' HUP

complete=0
child=0
cleanup() {
    if ((!complete && child != 0)); then
        signal_group "$child" 9
        wait "$child" 2>/dev/null
    fi
}
trap cleanup EXIT

if caller_gone || caller_replaced; then exit 125; fi
if ((pending != 0)); then exit $((128 + pending)); fi

payload=$(type -P -- "$1" 2>/dev/null) || payload=
if [[ -z $payload ]]; then
    printf '[abla-limit] cannot start command: %s: not found or not executable\n' "$1" >&2
    exit 127
fi
shift
# Job control puts the payload in a group of its own, whose id is its pid.
set -m
"$payload" ${1+"$@"} <&0 &
child=$!
set +m

started=$SECONDS
ticks=0
stopping=0
stop_started=0
stop_ticks=0
limit_ticks=$((seconds * 20))
grace_ticks=$((grace * 20))
while :; do
    if ((stopping == 0)); then
        forward=15
        if caller_gone || { ((ticks % 20 == 0)) && caller_replaced; }; then
            stopping=125
        elif ((pending != 0)); then
            stopping=$((128 + pending))
            forward=$pending
        elif ((ticks >= limit_ticks || SECONDS - started > seconds)); then
            stopping=124
        fi
        if ((stopping != 0)); then
            signal_group "$child" "$forward"
            stop_started=$SECONDS
            stop_ticks=0
        elif ! kill -0 "$child" 2>/dev/null; then
            # The payload is gone (bash reaped it and kept its status).
            status=0
            { wait "$child"; } 2>/dev/null || status=$?
            complete=1
            exit "$status"
        fi
    fi
    if ((stopping != 0 && (stop_ticks >= grace_ticks || SECONDS - stop_started > grace))); then
        # Even when the leader has exited a descendant may have ignored TERM.
        signal_group "$child" 9
        { wait "$child"; } 2>/dev/null
        complete=1
        exit "$stopping"
    fi
    sleep 0.05
    ticks=$((ticks + 1))
    ((stopping == 0)) || stop_ticks=$((stop_ticks + 1))
done
