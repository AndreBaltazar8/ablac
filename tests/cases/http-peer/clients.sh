#!/usr/bin/env bash
# Runs every mode of tests/cases/http-peer/server.ab against its Abla peer (client.ab):
# starts the server, waits for the port (or `ready`) it announces on standard error, runs
# the client against it, then requires the server to exit 0.
# Usage: clients.sh SERVER CLIENT CERTIFICATE KEY
set -euo pipefail
server=$1
client=$2
certificate=$3
key=$4
# A hung peer must not stall the suite; macOS has no timeout and runs unguarded.
guard=()
if command -v timeout >/dev/null 2>&1; then guard=(timeout 30); fi
modes=(sync4 sync6 mapped event noescape event6 noescape6 tls4 tls6 tlsws6 unix)
for mode in "${modes[@]}"; do
    directory=$(mktemp -d "${TMPDIR:-/tmp}/ab-peer-XXXXXX")
    socket=$directory/socket
    arguments=("$certificate" "$key")
    [[ $mode != unix ]] || arguments=("$socket")
    "$server" "$mode" "${arguments[@]}" > "$directory/stdout" 2> "$directory/stderr" &
    pid=$!
    ready=
    for _ in $(seq 1 300); do
        ready=$(head -n 1 "$directory/stderr" 2> /dev/null || true)
        [[ -z $ready ]] || break
        kill -0 "$pid" 2> /dev/null || break
        sleep 0.05
    done
    if [[ -z $ready ]]; then
        echo "$mode: the server did not become ready: $(cat "$directory/stderr")" >&2
        kill "$pid" 2> /dev/null || true
        exit 1
    fi
    target=$ready
    [[ $mode != unix ]] || target=$socket
    status=0
    ${guard[@]+"${guard[@]}"} "$client" "$mode" "$target" "$certificate" || status=$?
    if [[ $status != 0 ]]; then
        kill "$pid" 2> /dev/null || true
        echo "$mode: the client failed ($status)" >&2
        exit 1
    fi
    # The server ends by itself once it has answered; five seconds, as before.
    for _ in $(seq 1 100); do
        kill -0 "$pid" 2> /dev/null || break
        sleep 0.05
    done
    if kill -0 "$pid" 2> /dev/null; then
        kill "$pid" 2> /dev/null || true
        echo "$mode: the server did not exit" >&2
        exit 1
    fi
    server_status=0
    wait "$pid" || server_status=$?
    [[ $server_status == 0 ]] || { echo "$mode: server exit $server_status: $(cat "$directory/stderr")" >&2; exit 1; }
    rm -rf "$directory"
done
