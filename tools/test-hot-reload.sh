#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
test_directory=$(mktemp -d "$project_root/build/hot-reload.XXXXXX")
server=0

cleanup() {
    if [[ $server -gt 0 ]]; then
        pkill -TERM -s "$server" 2>/dev/null || true
        wait "$server" 2>/dev/null || true
    fi
    rm -rf -- "$test_directory"
}
trap cleanup EXIT

cp "$project_root/tests/cases/bootstrap/hot-reload-server.ab" \
    "$test_directory/app.ab"

wait_for_log() {
    local pattern=$1
    local attempt=0
    while [[ $attempt -lt 100 ]]; do
        if grep -q "$pattern" "$test_directory/stderr.txt" 2>/dev/null; then
            return 0
        fi
        sleep 0.1
        attempt=$((attempt + 1))
    done
    printf 'timed out waiting for hot-reload log: %s\n' "$pattern" >&2
    tail -40 "$test_directory/stderr.txt" >&2 || true
    return 1
}

setsid env ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=15 \
    "$compiler" serve "$test_directory/app.ab" \
    > "$test_directory/stdout.txt" 2> "$test_directory/stderr.txt" &
server=$!

wait_for_log 'reloaded generation 1'
cp "$project_root/tests/cases/bootstrap/invalid.ab" \
    "$test_directory/app.ab"
wait_for_log 'reload rejected; previous generation remains active'
cp "$project_root/tests/cases/bootstrap/hot-reload-server.ab" \
    "$test_directory/app.ab"
wait_for_log 'reloaded generation 3'

pkill -TERM -s "$server"
wait "$server" 2>/dev/null || true
server=0

[[ $(grep -c 'reloaded generation' "$test_directory/stderr.txt") -ge 2 ]]
grep -q 'reload rejected; previous generation remains active' \
    "$test_directory/stderr.txt"
if ! grep -Eq \
    'reloaded generation 3; modules: 1 refreshed, [1-9][0-9]* reused; parsed: [0-9]+ refreshed, [0-9]+ reused' \
    "$test_directory/stderr.txt"; then
    tail -40 "$test_directory/stderr.txt" >&2
    exit 1
fi

printf 'hot reload: valid -> rejected invalid -> recovered with unchanged dependency snapshots reused\n'
