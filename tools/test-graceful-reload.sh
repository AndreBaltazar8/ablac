#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1

test_directory=$(mktemp -d "$project_root/build/graceful-reload.XXXXXX")
supervisor=0
request=0

cleanup() {
    if [[ $request -gt 0 ]]; then
        kill "$request" 2>/dev/null || true
        wait "$request" 2>/dev/null || true
    fi
    if [[ $supervisor -gt 0 ]]; then
        kill -TERM -- "-$supervisor" 2>/dev/null || true
        wait "$supervisor" 2>/dev/null || true
    fi
    rm -rf -- "$test_directory"
}
trap cleanup EXIT

# setsid(1) is util-linux only: start the command in a new session portably.
# It execs in place, so a background job's $! leads the session's process
# group and `kill -- -$!` stops it and what it started.
new_session=(perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"')

cp "$project_root/tests/cases/bootstrap/graceful-http-v1.ab" \
    "$test_directory/app.ab"

wait_for_log() {
    local pattern=$1
    local attempt=0
    while [[ $attempt -lt 150 ]]; do
        if grep -q "$pattern" "$test_directory/stderr.txt" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    tail -60 "$test_directory/stderr.txt" >&2 || true
    return 1
}

# Each generation prints its port once it listens, just after the reload line.
wait_for_ports() {
    local count=$1
    local attempt=0
    while [[ $attempt -lt 150 ]]; do
        if [[ $(grep -cE '^[0-9]+$' "$test_directory/stderr.txt" 2>/dev/null) -ge $count ]]; then
            return 0
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    tail -60 "$test_directory/stderr.txt" >&2 || true
    return 1
}

"${new_session[@]}" env ABLA_MAX_MEMORY_MB=1536 ABLA_MAX_SECONDS=20 \
    "$compiler" serve "$test_directory/app.ab" \
    > "$test_directory/stdout.txt" 2> "$test_directory/stderr.txt" &
supervisor=$!

wait_for_log 'reloaded generation 1'
wait_for_ports 1
port=$(grep -E '^[0-9]+$' "$test_directory/stderr.txt" | tail -1)
[[ $port =~ ^[0-9]+$ ]] || exit 1

curl --silent --fail --max-time 6 "http://127.0.0.1:$port/slow" \
    > "$test_directory/v1.txt" &
request=$!
wait_for_log 'request-start-v1'

cp "$project_root/tests/cases/bootstrap/graceful-http-v2.ab" \
    "$test_directory/app.ab"
wait_for_log 'reloaded generation 2'
wait "$request"
request=0
[[ $(< "$test_directory/v1.txt") == slow-v1 ]] || exit 1

wait_for_ports 2
next_port=$(grep -E '^[0-9]+$' "$test_directory/stderr.txt" | tail -1)
[[ $next_port =~ ^[0-9]+$ ]] || exit 1
curl --silent --fail --max-time 6 \
    "http://127.0.0.1:$next_port/slow" > "$test_directory/v2.txt"
[[ $(< "$test_directory/v2.txt") == slow-v2 ]] || exit 1

printf '%s\n' 'graceful reload: active V1 request drained before V2 handoff'
