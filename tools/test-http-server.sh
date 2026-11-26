#!/usr/bin/env bash
set -euo pipefail

run_only=0
if [[ ${1:-} == --run ]]; then
    run_only=1
    shift
fi
if (( (!run_only && $# != 1) || $# == 0 )); then
    printf 'usage: %s <self-hosted-compiler> | --run <server-command> [args...]\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
test_directory=$(mktemp -d "$project_root/build/http-server.XXXXXX")
server=0

cleanup() {
    if [[ $server -gt 0 ]]; then
        kill -TERM -- "-$server" 2>/dev/null || true
        wait "$server" 2>/dev/null || true
    fi
    rm -rf -- "$test_directory"
}
trap cleanup EXIT

# setsid(1) is util-linux only: start the command in a new session portably.
# It execs in place, so a background job's $! leads the session's process
# group and `kill -- -$!` stops it and what it started.
new_session=(perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"')

if ((run_only)); then
    command=("$@")
else
    "$1" build "$project_root/tests/cases/modules/http-server.ab" \
        -o "$test_directory/server"
    # The host object is the syscall layer on macOS only.
    [[ $(uname -s) == Darwin || ! -e $test_directory/server.host.o ]] || exit 1
    symbols=$(nm "$test_directory/server" | awk '{print $3}')
    if rg -q '^(ablaHost|abla_host_)' <<< "$symbols"; then
        printf '%s\n' 'raw HTTP server linked hosted capability symbols' >&2
        exit 1
    fi

    # The CPU budget is independent of load; the wall-clock limit ends a hang.
    command=(env ABLA_MAX_MEMORY_MB=64 ABLA_MAX_SECONDS=300 ABLA_MAX_CPU_SECONDS=15
        "$project_root/tools/run-limited.sh" "$test_directory/server")
fi
"${new_session[@]}" "${command[@]}" \
    > "$test_directory/stdout.txt" 2> "$test_directory/stderr.txt" &
server=$!

# The server's first stderr line is its port: wait for that line for as long as the server runs
# (a loaded machine may start it late), not for a fixed window.
port=""
while :; do
    port=$(sed -n '1p' "$test_directory/stderr.txt" 2>/dev/null || true)
    [[ $port =~ ^[0-9]+$ ]] && break
    kill -0 "$server" 2>/dev/null || break
    sleep 0.05
done
if [[ ! $port =~ ^[0-9]+$ ]]; then
    echo 'http server: it ended before it listened' >&2
    cat "$test_directory/stderr.txt" >&2
    if ((run_only)); then
        status=0
        wait "$server" || status=$?
        server=0
        if ((status == 124)); then exit 124; fi
    fi
    exit 1
fi

curl --silent --fail --max-time 60 \
    "http://127.0.0.1:$port/health" > "$test_directory/health.txt"
curl --silent --fail --max-time 60 -H 'Stripe-Version: 2024-06-01' \
    "http://127.0.0.1:$port/customers/42" > "$test_directory/v1.txt"
curl --silent --fail --max-time 60 \
    "http://127.0.0.1:$port/customers/42" > "$test_directory/latest.txt"

set +e
wait "$server"
status=$?
set -e
server=0

if ((run_only && status == 124)); then exit 124; fi
[[ $status -eq 42 ]] || exit 1
[[ $(< "$test_directory/health.txt") == healthy ]] || exit 1
[[ $(< "$test_directory/v1.txt") == v1:42 ]] || exit 1
[[ $(< "$test_directory/latest.txt") == v1:42:v2 ]] || exit 1

if ((run_only)); then
    printf '%s\n' "$(< "$test_directory/health.txt")" "$(< "$test_directory/v1.txt")" "$(< "$test_directory/latest.txt")"
    exit 42
fi
printf 'raw-syscall HTTP server: health + versioned V1 + latest V2; no hosted capability\n'
