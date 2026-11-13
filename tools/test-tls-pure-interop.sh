#!/usr/bin/env bash
# abla/tls/pure against `openssl s_server -tls1_3`, with the real certificate check (abla/crypto/x509 on the
# server's self-signed certificate as the trust anchor, then the CertificateVerify under its key): one run per
# certificate type (Ed25519, ECDSA P-256, ECDSA P-384, RSA-2048 with RSA-PSS), cipher suite (AES-128-GCM, AES-256-GCM, ChaCha20-Poly1305) and key-exchange
# group (X25519, and P-256 only, which makes the server send a HelloRetryRequest), each with a request and
# response, close_notify and a wrong-host-name refusal; then a 6 MB download (tests/cases/tls-pure/bulk.ab).
# Skipped, with a message, without an openssl that does TLS 1.3 and Ed25519. Usage:
#   tools/test-tls-pure-interop.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/tls-pure-interop
rm -rf "$out"
mkdir -p "$out"
if ! command -v openssl > /dev/null || ! openssl genpkey -algorithm ED25519 -out "$out/ed25519.key" 2> /dev/null; then
    echo 'tls-pure interop: no openssl with Ed25519; skipped'
    exit 0
fi
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/p256.key" 2> /dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$out/p384.key" 2> /dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$out/rsa.key" 2> /dev/null
for kind in ed25519 p256 p384 rsa; do
    openssl req -x509 -new -key "$out/$kind.key" -out "$out/$kind.pem" -subj /CN=localhost \
        -addext 'subjectAltName=DNS:localhost' -days 2 2> /dev/null
done
"$compiler" build tests/cases/tls-pure/interop.ab -o "$out/interop" --no-cache
server_pid=
trap '[[ -z $server_pid ]] || kill "$server_pid" 2> /dev/null || true' EXIT
start_server() {   # key kind, then the s_server options
    local kind=$1
    shift
    port=$(( 20000 + RANDOM % 20000 ))
    openssl s_server -accept "$port" -cert "$out/$kind.pem" -key "$out/$kind.key" -tls1_3 "$@" > "$out/server.log" 2>&1 &
    server_pid=$!
    for _ in $(seq 50); do
        grep -q ACCEPT "$out/server.log" 2> /dev/null && break
        kill -0 "$server_pid" 2> /dev/null || { echo "tls-pure interop: s_server did not start: $(head -3 "$out/server.log")" >&2; exit 1; }
        sleep 0.1
    done
}
stop_server() {
    kill "$server_pid" 2> /dev/null || true
    wait "$server_pid" 2> /dev/null || true
    server_pid=
}
runs=0
for kind in ed25519 p256 p384 rsa; do
    for suite in TLS_AES_128_GCM_SHA256:4865 TLS_AES_256_GCM_SHA384:4866 TLS_CHACHA20_POLY1305_SHA256:4867; do
        for group in X25519 P-256; do
            start_server "$kind" -www -ciphersuites "${suite%:*}" -groups "$group"
            result=$("$root/tools/run-limited.sh" "$out/interop" "$port" "$out/$kind.pem" "${suite#*:}" "$out/$([[ $kind == p256 ]] && echo rsa || echo p256).pem") || {
                echo "tls-pure interop ($kind ${suite%:*} $group): $result" >&2; head -5 "$out/server.log" >&2; exit 1; }
            [[ $result == 'tls-pure interop ok'* ]] || { echo "tls-pure interop ($kind ${suite%:*} $group): $result" >&2; exit 1; }
            stop_server
            runs=$((runs + 1))
        done
    done
    echo "$kind: ok"
done
echo "$runs handshakes (4 certificate types x 3 suites x 2 groups, the P-256 ones through a HelloRetryRequest)"
# A bulk transfer: a 6 MB file, many records; size and SHA-256 must match (Ed25519, checked in the program).
"$compiler" build tests/cases/tls-pure/bulk.ab -o "$out/bulk" --no-cache
mkdir -p "$out/www"
head -c 6291456 /dev/urandom > "$out/www/big.bin"
expected=$(sha256sum "$out/www/big.bin" | cut -d' ' -f1)
public=$(openssl pkey -in "$out/ed25519.key" -pubout -outform DER | tail -c 32 | od -An -vtx1 | tr -d ' \n')
port=$(( 20000 + RANDOM % 20000 ))
(cd "$out/www" && exec openssl s_server -accept "$port" -cert ../ed25519.pem -key ../ed25519.key -tls1_3 -HTTP -groups X25519 > ../server-bulk.log 2>&1) &
server_pid=$!
for _ in $(seq 50); do
    grep -q ACCEPT "$out/server-bulk.log" 2> /dev/null && break
    sleep 0.1
done
result=$("$root/tools/run-limited.sh" "$out/bulk" "$port" "$public" /big.bin 6291456 "$expected") || { echo "tls-pure bulk: $result" >&2; head -5 "$out/server-bulk.log" >&2; exit 1; }
[[ $result == 'tls-pure bulk ok'* ]] || { echo "tls-pure bulk: $result" >&2; exit 1; }
echo "$result"
stop_server
echo 'tls-pure interop ok'
