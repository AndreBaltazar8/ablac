#!/usr/bin/env bash
# abla/tls/pure against `openssl s_server -tls1_3` (an Ed25519 certificate, X25519, AES-GCM): the whole
# handshake including the CertificateVerify, a request and its response, close_notify; once per cipher
# suite and with the server's group offered as X25519. Skipped, with a message, without an openssl that
# does TLS 1.3 and Ed25519. Usage: tools/test-tls-pure-interop.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/tls-pure-interop
rm -rf "$out"
mkdir -p "$out"
if ! command -v openssl > /dev/null || ! openssl genpkey -algorithm ED25519 -out "$out/key.pem" 2> /dev/null; then
    echo 'tls-pure interop: no openssl with Ed25519; skipped'
    exit 0
fi
openssl req -x509 -new -key "$out/key.pem" -out "$out/cert.pem" -subj /CN=localhost -days 2 2> /dev/null
public=$(openssl pkey -in "$out/key.pem" -pubout -outform DER | tail -c 32 | od -An -vtx1 | tr -d ' \n')
"$compiler" build tests/cases/tls-pure/interop.ab -o "$out/interop" --no-cache
server_pid=
trap '[[ -z $server_pid ]] || kill "$server_pid" 2> /dev/null || true' EXIT
for suite in TLS_AES_128_GCM_SHA256 TLS_AES_256_GCM_SHA384; do
    port=$(( 20000 + RANDOM % 20000 ))
    openssl s_server -accept "$port" -cert "$out/cert.pem" -key "$out/key.pem" -tls1_3 -www \
        -ciphersuites "$suite" -groups X25519 > "$out/server.log" 2>&1 &
    server_pid=$!
    for _ in $(seq 50); do
        grep -q ACCEPT "$out/server.log" 2> /dev/null && break
        kill -0 "$server_pid" 2> /dev/null || { echo "tls-pure interop: s_server did not start: $(head -3 "$out/server.log")" >&2; exit 1; }
        sleep 0.1
    done
    result=$("$root/tools/run-limited.sh" "$out/interop" "$port" "$public") || { echo "tls-pure interop ($suite): $result" >&2; head -5 "$out/server.log" >&2; exit 1; }
    [[ $result == 'tls-pure interop ok'* ]] || { echo "tls-pure interop ($suite): $result" >&2; exit 1; }
    echo "$suite: $result"
    kill "$server_pid" 2> /dev/null || true
    wait "$server_pid" 2> /dev/null || true
    server_pid=
done
echo 'tls-pure interop ok'
