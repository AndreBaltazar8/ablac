#!/usr/bin/env bash
# The read deadline of the WebSocket TLS client (abla/websocket/tls): readFrame(maximumPayload, timeoutMilliseconds) and setReadTimeout bound the whole wait for a
# frame (a frame cut short, a frame that drips in a byte at a time, a quiet peer); the bytes read stay buffered and the connection open; the default (0) is the
# old behaviour, no limit. Server: abla/websocket/server/tls in a forked child, with a certificate made here. Then the masking (masks.ab): a fresh key per
# frame the client sends, and a masked frame from the server refused.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory=$project_root/build/websocket-tls-client
rm -rf "$output_directory"
mkdir -p "$output_directory"
cd "$project_root"
cp tests/vectors/crypto/test-keys/tls-server.pem "$output_directory/private-key.pem"
openssl req -x509 -new -key "$output_directory/private-key.pem" -days 2 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost -out "$output_directory/certificate.pem" 2>/dev/null
"$project_root/tools/run-limited.sh" "$compiler" build tests/cases/websocket-tls-client/client.ab -o "$output_directory/client"
set +e
output=$(ABLA_MAX_SECONDS=60 ABLA_MAX_CPU_SECONDS=60 "$project_root/tools/run-limited.sh" "$output_directory/client" 2>&1 </dev/null)
status=$?
set -e
output=${output//$'\r'/}
[[ $status -eq 42 && $output == 'websocket-tls-client: ok' ]] ||
    { printf 'websocket-tls-client: status %s\n%s\n' "$status" "$output" >&2; exit 1; }
echo 'websocket-tls-client: the read deadline holds'
# Each frame the client sends has a masking key of its own, and a masked frame from the server fails the connection (tests/cases/websocket-tls-client/masks.ab).
"$project_root/tools/run-limited.sh" "$compiler" build tests/cases/websocket-tls-client/masks.ab -o "$output_directory/masks"
set +e
output=$(ABLA_MAX_SECONDS=60 ABLA_MAX_CPU_SECONDS=60 "$project_root/tools/run-limited.sh" "$output_directory/masks" 2>&1 </dev/null)
status=$?
set -e
output=${output//$'\r'/}
[[ $status -eq 42 && $output == 'websocket-tls-client masks: ok' ]] ||
    { printf 'websocket-tls-client masks: status %s\n%s\n' "$status" "$output" >&2; exit 1; }
echo 'websocket-tls-client: a fresh masking key per frame, a masked server frame refused'
