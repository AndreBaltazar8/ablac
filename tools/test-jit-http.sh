#!/usr/bin/env bash
# An HTTP server runs under `ablac run --jit`: it answers a health check and a
# versioned route, then exits 42.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
test_directory=$(mktemp -d "$project_root/build/jit-http.XXXXXX")
server=0

# The server runs in the background (macOS has no setsid); a failed check
# stops it and whatever it started.
cleanup() {
    if [[ $server -gt 0 ]]; then
        pkill -TERM -P "$server" 2>/dev/null || true
        kill -TERM "$server" 2>/dev/null || true
        wait "$server" 2>/dev/null || true
    fi
    rm -rf -- "$test_directory"
}
trap cleanup EXIT

ABLA_MAX_MEMORY_MB=768 ABLA_MAX_SECONDS=60 \
    "$compiler" run --jit "$project_root/tests/cases/modules/http-server.ab" \
    > "$test_directory/stdout.txt" 2> "$test_directory/stderr.txt" &
server=$!

port=""
for attempt in {1..600}; do
    port=$(sed -n '1p' "$test_directory/stderr.txt" 2>/dev/null || true)
    if [[ $port =~ ^[0-9]+$ ]]; then
        break
    fi
    sleep 0.05
done
[[ $port =~ ^[0-9]+$ ]] || exit 1

curl --silent --fail --max-time 2 \
    "http://127.0.0.1:$port/health" > "$test_directory/health.txt"
curl --silent --fail --max-time 2 -H 'Stripe-Version: 2024-06-01' \
    "http://127.0.0.1:$port/customers/42" > "$test_directory/v1.txt"
curl --silent --fail --max-time 2 \
    "http://127.0.0.1:$port/customers/42" > "$test_directory/latest.txt"

set +e
wait "$server"
status=$?
set -e
server=0

[[ $status -eq 42 ]] || exit 1
[[ $(< "$test_directory/health.txt") == healthy ]] || exit 1
[[ $(< "$test_directory/v1.txt") == v1:42 ]] || exit 1
[[ $(< "$test_directory/latest.txt") == v1:42:v2 ]] || exit 1

printf 'JIT HTTP server: health + versioned V1 + latest V2\n'
