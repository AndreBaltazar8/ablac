#!/usr/bin/env bash
# The WebSocket server over TLS (abla/websocket/server/tls), with a self-signed
# certificate made here: a wss round trip (text, ping, binary, close), manual
# admission accepted and rejected, an HTTP route, a 1 MB message echoed three
# times in partial writes, a PEM-text configuration, a client that never
# handshakes (dropped at the handshake timeout while the others are served)
# and a plaintext request at the TLS port. A plain server must not link OpenSSL.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory=$project_root/build/websocket-tls-server
mkdir -p "$output_directory"
cd "$project_root"

openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost \
    -keyout "$output_directory/private-key.pem" \
    -out "$output_directory/certificate.pem" 2>/dev/null

"$project_root/tools/run-limited.sh" "$compiler" build \
    tests/cases/modules/websocket-tls-server.ab \
    -o "$output_directory/websocket-tls-server" --no-cache
set +e
output=$(ABLA_MAX_SECONDS=60 ABLA_MAX_CPU_SECONDS=60 \
    "$project_root/tools/run-limited.sh" "$output_directory/websocket-tls-server" 2>&1)
status=$?
set -e
[[ $status -eq 42 && $output == 'websocket-tls-server: ok' ]] ||
    { printf 'websocket-tls-server: status %s\n%s\n' "$status" "$output" >&2; exit 1; }

# The plain server keeps its link: no OpenSSL.
"$project_root/tools/run-limited.sh" "$compiler" build \
    tests/cases/modules/websocket-server.ab \
    -o "$output_directory/websocket-server" --no-cache
if [[ $(uname) == Darwin ]]; then
    libraries=$(otool -L "$output_directory/websocket-server")
else
    libraries=$(ldd "$output_directory/websocket-server")
fi
if [[ $libraries == *libssl* ]]; then
    echo 'websocket-tls-server: a plain server links OpenSSL' >&2
    exit 1
fi
echo 'websocket-tls-server: ok'
