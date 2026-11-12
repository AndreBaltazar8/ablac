#!/usr/bin/env bash
# SIGTERM must wake idle HTTP/WebSocket readiness loops, not wait for their
# one-second poll timeout. Wait for epoll before timing, excluding startup.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s) != Linux ]]; then
    echo 'event shutdown: skipped outside Linux'
    exit 0
fi
out="$root/build/event-shutdown"
mkdir -p "$out"
"$compiler" build "$root/tests/cases/bootstrap/event-shutdown.ab" \
    -o "$out/program" --fast --no-cache
fail() { echo "event shutdown: $1" >&2; exit 1; }
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
# gone PID: the process has exited (a zombie not yet reaped by `wait` counts).
gone() {
    local state
    state=$(awk '{ print $3 }' "/proc/$1/stat" 2> /dev/null) || return 0
    [[ -z $state || $state == Z ]]
}
program_pid=
trap 'if [[ -n $program_pid ]] && ! gone "$program_pid"; then kill -KILL "$program_pid" 2> /dev/null || true; fi; wait 2> /dev/null || true' EXIT
for mode in http websocket; do
    for trial in 1 2; do
        : > "$out/port"
        "$out/program" "$mode" > "$out/port" 2> "$out/stderr" &
        program_pid=$!
        # The program prints its listening port; wait for that line (10 s).
        port=
        deadline=$(( $(now_ms) + 10000 ))
        while [[ -z $port && $(now_ms) -lt $deadline ]]; do
            port=$(head -n 1 "$out/port")
            [[ -n $port ]] || sleep 0.01
        done
        [[ $port =~ ^[0-9]+$ ]] || fail "$mode: no listening port"
        # Give the loop a socket event, then observe it waiting again so the old
        # timeout has almost its full second left.
        exec 3<> "/dev/tcp/127.0.0.1/$port"
        exec 3>&-
        waiting=0
        deadline=$(( $(now_ms) + 5000 ))
        while [[ $(now_ms) -lt $deadline ]] && ! gone "$program_pid"; do
            state=$(cat "/proc/$program_pid/wchan" 2> /dev/null || true)
            if [[ $state == *epoll* || $state == *ep_poll* ]]; then waiting=1; break; fi
            sleep 0.001
        done
        [[ $waiting -eq 1 ]] || fail "$mode: never entered epoll wait"
        began=$(now_ms)
        kill -TERM "$program_pid"
        deadline=$((began + 500))
        while ! gone "$program_pid" && [[ $(now_ms) -lt $deadline ]]; do sleep 0.002; done
        gone "$program_pid" || fail "$mode: SIGTERM did not wake the idle server within 500ms"
        elapsed=$(( $(now_ms) - began ))
        status=0
        wait "$program_pid" || status=$?
        program_pid=
        [[ $status -eq 42 ]] || fail "$mode: shutdown status $status, expected 42"
        echo "$mode: idle SIGTERM shutdown ${elapsed}ms"
    done
done
