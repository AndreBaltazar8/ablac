#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/http-client"
program="$output_directory/program"
ready="$output_directory/ready"
mkdir -p "$output_directory"
rm -f "$ready"

# The server listens on a port the system picks (tests run in parallel) and
# writes it to $ready; the client program is built with that port.
python3 - "$ready" <<'PY' &
import os
import socket
import sys

ready = sys.argv[1]
server = socket.socket()
server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
server.bind(("127.0.0.1", 0))
server.listen(1)
port = server.getsockname()[1]
with open(ready + ".next", "w") as published:
    published.write(str(port))
os.rename(ready + ".next", ready)
connection, _ = server.accept()
request = connection.recv(65536)
host = b"Host: localhost:" + str(port).encode() + b"\r\n"
valid = request.startswith(b"GET /hello HTTP/1.1\r\n") and host in request
body = b"hello" if valid else b"bad"
connection.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body)
connection.close()
server.close()
PY
server_pid=$!
trap 'kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true' EXIT

for _ in $(seq 1 500); do
    [[ -e $ready ]] && break
    sleep 0.02
done
[[ -e $ready ]] || exit 1
port=$(<"$ready")
sed "s/39092/$port/g" "$project_root/tests/cases/http-client-ipv4.ab" \
    > "$output_directory/http-client-ipv4.ab"

"$compiler" build "$output_directory/http-client-ipv4.ab" \
    -o "$program" --fast --no-cache
set +e
"$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
wait "$server_pid"
trap - EXIT
[[ $status -eq 42 ]] || exit 1

# The same exchanges against the program's own loopback listener.
"$compiler" build "$project_root/tests/cases/modules/http-client.ab" \
    -o "$output_directory/loopback" --fast --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/loopback"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1

printf '%s\n' 'HTTP client: bounded raw IPv4 exchange + pluggable TLS transport passed'
