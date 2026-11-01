#!/usr/bin/env bash
# The WebSocket server over TLS (abla/websocket/server/tls), with a self-signed
# certificate made here: a wss round trip (text, ping, binary, close), manual
# admission accepted and rejected, an HTTP route, a 1 MB message echoed three
# times in partial writes, a PEM-text configuration (an encrypted key refused
# without asking for its passphrase on the terminal), a client that never
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
openssl pkey -in "$output_directory/private-key.pem" -aes256 -passout pass:secret \
    -out "$output_directory/encrypted-key.pem"

"$project_root/tools/run-limited.sh" "$compiler" build \
    tests/cases/modules/websocket-tls-server.ab \
    -o "$output_directory/websocket-tls-server"
# On a terminal, as OpenSSL asks for a missing passphrase on one: a run that asks
# hangs here until its limit.
run=("$project_root/tools/run-limited.sh" "$output_directory/websocket-tls-server")
if command -v script >/dev/null 2>&1; then
    printf -v quoted '%q ' "${run[@]}"
    run=(script -qfec "$quoted" /dev/null)
fi
set +e
output=$(ABLA_MAX_SECONDS=60 ABLA_MAX_CPU_SECONDS=60 "${run[@]}" 2>&1 </dev/null)
status=$?
set -e
output=${output//$'\r'/}
[[ $status -eq 42 && $output == 'websocket-tls-server: ok' ]] ||
    { printf 'websocket-tls-server: status %s\n%s\n' "$status" "$output" >&2; exit 1; }

# The plain server keeps its link: no OpenSSL.
"$project_root/tools/run-limited.sh" "$compiler" build \
    tests/cases/modules/websocket-server.ab \
    -o "$output_directory/websocket-server"
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
