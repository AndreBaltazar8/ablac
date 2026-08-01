#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/http-client"
program="$output_directory/program"
ready="$output_directory/ready"
mkdir -p "$output_directory"
rm -f "$ready"

python3 - "$ready" <<'PY' &
import socket
import sys

ready = sys.argv[1]
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 39092))
server.listen(1)
open(ready, "w").close()
connection, _ = server.accept()
request = connection.recv(65536)
valid = request.startswith(b"GET /hello HTTP/1.1\r\n") and b"Host: localhost:39092\r\n" in request
body = b"hello" if valid else b"bad"
connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
connection.close()
server.close()
PY
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true' EXIT

for _ in $(seq 1 100); do
    [[ -e $ready ]] && break
    sleep 0.02
done
[[ -e $ready ]]

"$compiler" build "$project_root/tests/cases/modules/http-client.ab" \
    -o "$program" --fast --no-cache
set +e
"$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
wait "$server_pid"
trap - EXIT
[[ $status -eq 42 ]]

printf '%s\n' 'HTTP client: bounded raw IPv4 exchange + pluggable TLS transport passed'
