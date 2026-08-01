#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'usage: %s <self-hosted-compiler> <abla-orc-runner>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
runner=$2
test_directory=$(mktemp -d "$project_root/build/orc-http.XXXXXX")
server=0

cleanup() {
    if [[ $server -gt 0 ]]; then
        pkill -TERM -s "$server" 2>/dev/null || true
        wait "$server" 2>/dev/null || true
    fi
    rm -rf -- "$test_directory"
}
trap cleanup EXIT

"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/http-server.ab" \
    > "$test_directory/server.ll"

setsid env ABLA_MAX_MEMORY_MB=1024 ABLA_MAX_SECONDS=20 \
    "$project_root/tools/run-limited.sh" "$runner" \
    "$test_directory/server.ll" \
    > "$test_directory/stdout.txt" 2> "$test_directory/stderr.txt" &
server=$!

port=""
for attempt in {1..100}; do
    port=$(sed -n '1p' "$test_directory/stderr.txt" 2>/dev/null || true)
    if [[ $port =~ ^[0-9]+$ ]]; then
        break
    fi
    sleep 0.05
done
[[ $port =~ ^[0-9]+$ ]]

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

[[ $status -eq 42 ]]
[[ $(< "$test_directory/health.txt") == healthy ]]
[[ $(< "$test_directory/v1.txt") == v1:42 ]]
[[ $(< "$test_directory/latest.txt") == v1:42:v2 ]]

printf 'Abla ORC HTTP server: health + versioned V1 + latest V2\n'
