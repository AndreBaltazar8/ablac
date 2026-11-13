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
# Starts s_server for the key kind with the given options on a free port (in $port), in $server_directory
# (default the current one). A port someone else (a parallel suite) took in between makes the bind fail:
# pick another and try again, a few times.
start_server() {
    local kind=$1
    shift
    local attempt
    for attempt in 1 2 3 4 5 6 7 8; do
        port=$(( 20000 + RANDOM % 20000 ))
        # (A test hook: TLS_PURE_FIRST_PORT forces the first attempt of each start onto a port, to exercise the retry.)
        [[ $attempt -eq 1 && -n ${TLS_PURE_FIRST_PORT:-} ]] && port=$TLS_PURE_FIRST_PORT
        (cd "${server_directory:-.}" && exec openssl s_server -accept "$port" -cert "$root/$out/$kind.pem" -key "$root/$out/$kind.key" -tls1_3 "$@") > "$out/server.log" 2>&1 &
        server_pid=$!
        local started=0
        for _ in $(seq 50); do
            if grep -q ACCEPT "$out/server.log" 2> /dev/null; then started=1; break; fi
            kill -0 "$server_pid" 2> /dev/null || break
            sleep 0.1
        done
        [[ $started -eq 1 ]] && return 0
        kill "$server_pid" 2> /dev/null || true
        wait "$server_pid" 2> /dev/null || true
        server_pid=
        grep -q 'Address already in use' "$out/server.log" || break
    done
    echo "tls-pure interop: s_server did not start on port $port after $attempt attempt(s): $(head -3 "$out/server.log")" >&2
    exit 1
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
# The hosted-API-compatible surface (abla/tls/pure: tlsConnectWithCa, TlsConnection, tlsLastError ...).
"$compiler" build tests/cases/tls-pure/api.ab -o "$out/api" --no-cache
start_server ed25519 -www -groups X25519
result=$("$root/tools/run-limited.sh" "$out/api" "$port" "$out/ed25519.pem" "$out/rsa.pem") || { echo "tls-pure api: $result" >&2; head -5 "$out/server.log" >&2; exit 1; }
[[ $result == 'tls-pure api ok' ]] || { echo "tls-pure api: $result" >&2; exit 1; }
echo "$result"
stop_server
# Client identities from PEM (every key kind and encoding), then mutual TLS: s_server -Verify trusting one client
# certificate; that client is accepted, one with no identity and one with another certificate are refused.
openssl rsa -in "$out/rsa.key" -traditional -out "$out/rsa-alt.key" 2> /dev/null
openssl ec -in "$out/p256.key" -out "$out/p256-alt.key" 2> /dev/null
openssl pkcs8 -topk8 -v2 aes-256-cbc -iter 2000 -in "$out/rsa.key" -passout pass:secret -out "$out/rsa-enc.key" 2> /dev/null
"$compiler" build tests/cases/tls-pure/identity.ab -o "$out/identity" --no-cache
result=$("$root/tools/run-limited.sh" "$out/identity" "$out") || { echo "tls-pure identity: $result" >&2; exit 1; }
[[ $result == 'tls-pure identity ok' ]] || { echo "tls-pure identity: $result" >&2; exit 1; }
echo "$result"
"$compiler" build tests/cases/tls-pure/mtls.ab -o "$out/mtls" --no-cache
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$out/client-rsa.key" 2> /dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/client-p256.key" 2> /dev/null
openssl genpkey -algorithm ED25519 -out "$out/client-ed25519.key" 2> /dev/null
for kind in rsa p256 ed25519; do
    openssl req -x509 -new -key "$out/client-$kind.key" -out "$out/client-$kind.pem" -subj /CN=client-$kind -days 2 2> /dev/null
done
for kind in rsa p256 ed25519; do
    other=$([[ $kind == rsa ]] && echo p256 || echo rsa)
    start_server ed25519 -www -groups X25519 -Verify 1 -CAfile "$out/client-$kind.pem" -verify_return_error
    for case in "accepted:client-$kind" "refused:none" "refused:client-$other"; do
        expect=${case%%:*}
        who=${case#*:}
        certificate=$([[ $who == none ]] && echo none || echo "$out/$who.pem")
        result=$("$root/tools/run-limited.sh" "$out/mtls" "$port" "$out/ed25519.pem" "$certificate" "$out/$who.key" "$expect") || {
            echo "tls-pure mtls ($kind trusted, $who): $result" >&2; head -5 "$out/server.log" >&2; exit 1; }
        [[ $result == "tls-pure mtls ok ($expect)" ]] || { echo "tls-pure mtls ($kind trusted, $who): $result" >&2; exit 1; }
    done
    stop_server
    echo "mtls $kind: accepted, refused without an identity, refused with another"
done
# TLS 1.2 building blocks: the PRF against `openssl kdf TLS1-PRF` (random secrets and seeds, SHA-256 and SHA-384, the
# labels TLS 1.2 uses), the key block, the AEAD record layer for three suites, the message codecs.
"$compiler" build tests/cases/tls-pure/tls12prf.ab -o "$out/tls12prf" --no-cache
hex() { od -An -vtx1 | tr -d ' \n'; }
prf_args=()
for spec in "SHA256 48 master secret" "SHA256 12 client finished" "SHA384 104 key expansion" "SHA384 12 server finished" "SHA256 104 key expansion" "SHA384 48 extended master secret"; do
    set -- $spec
    digest=$1; length=$2; shift 2; label="$*"
    secret=$(head -c 48 /dev/urandom | hex); seed=$(head -c 64 /dev/urandom | hex)
    expected=$(openssl kdf -keylen "$length" -kdfopt digest:"$digest" -kdfopt hexsecret:"$secret" -kdfopt hexseed:"$(printf %s "$label" | hex)$seed" TLS1-PRF 2> /dev/null | tr -d ':' | tr 'A-F' 'a-f') || expected=
    if [[ -z $expected ]]; then echo 'tls-pure tls12: this openssl has no kdf TLS1-PRF; the PRF is not compared'; prf_args=(); break; fi
    prf_args+=("$digest" "$secret" "$label" "$seed" "$length" "$expected")
done
result=$("$root/tools/run-limited.sh" "$out/tls12prf" "${prf_args[@]}") || { echo "tls-pure tls12 blocks: $result" >&2; exit 1; }
[[ $result == 'tls-pure tls12 ok'* ]] || { echo "tls-pure tls12 blocks: $result" >&2; exit 1; }
echo "$result"
# The sans-IO server against the sans-IO client in one process (tests/cases/tls-pure/server.ab): every key kind x suite x
# group (HelloRetryRequest), 70 KB each way, ALPN, client certificates, KeyUpdate, refusals, damaged input.
"$compiler" build tests/cases/tls-pure/server.ab -o "$out/server" --no-cache
result=$("$root/tools/run-limited.sh" "$out/server" "$out") || { echo "tls-pure server (in process): $result" >&2; exit 1; }
[[ $result == 'tls-pure server ok' ]] || { echo "tls-pure server (in process): $result" >&2; exit 1; }
echo "$result"
# abla/tls/pure as the SERVER: tests/cases/tls-pure/serve.ab (listening on ::1 on a free port) against openssl s_client
# (every key kind x cipher suite x group, so the P-256 ones through a HelloRetryRequest), against the pure client,
# with ALPN, and requiring a client certificate.
"$compiler" build tests/cases/tls-pure/serve.ab -o "$out/serve" --no-cache
serve_pid=
stop_serve() {
    [[ -z $serve_pid ]] || { kill "$serve_pid" 2> /dev/null || true; wait "$serve_pid" 2> /dev/null || true; }
    serve_pid=
}
trap 'stop_serve; [[ -z $server_pid ]] || kill "$server_pid" 2> /dev/null || true' EXIT
start_serve() {   # the serve.ab arguments; sets serve_port
    "$out/serve" "$@" > "$out/serve.log" 2>&1 &
    serve_pid=$!
    for _ in $(seq 100); do
        grep -q '^listening ' "$out/serve.log" 2> /dev/null && break
        kill -0 "$serve_pid" 2> /dev/null || { echo "tls-pure serve: did not start: $(head -3 "$out/serve.log")" >&2; exit 1; }
        sleep 0.1
    done
    serve_port=$(sed -n 's/^listening //p' "$out/serve.log" | head -1)
    [[ -n $serve_port ]] || { echo "tls-pure serve: no port: $(head -3 "$out/serve.log")" >&2; exit 1; }
}
s_client() {   # the s_client options after the address; prints what the server sent
    printf 'GET /pure HTTP/1.0\r\n\r\n' | timeout 15 openssl s_client -connect "[::1]:$serve_port" -tls1_3 -servername localhost -quiet "$@" 2> "$out/s_client.err" || true
}
served=0
for kind in ed25519 p256 rsa; do
    start_serve plain "$out/$kind.pem" "$out/$kind.key"
    for suite in TLS_AES_128_GCM_SHA256 TLS_AES_256_GCM_SHA384 TLS_CHACHA20_POLY1305_SHA256; do
        for group in X25519 P-256; do
            answer=$(s_client -ciphersuites "$suite" -groups "$group" -CAfile "$out/$kind.pem" -verify_return_error -verify_hostname localhost)
            [[ $answer == *'pure server: GET /pure'* ]] || { echo "tls-pure server ($kind $suite $group): [$answer] $(head -3 "$out/s_client.err") $(head -3 "$out/serve.log")" >&2; exit 1; }
            served=$((served + 1))
        done
    done
    # The pure client against it (one good connection, a wrong host name, an untrusted anchor).
    result=$("$root/tools/run-limited.sh" "$out/interop" "$serve_port" "$out/$kind.pem" 4865 "$out/$([[ $kind == p256 ]] && echo rsa || echo p256).pem") || {
        echo "tls-pure client vs pure server ($kind): $result" >&2; head -3 "$out/serve.log" >&2; exit 1; }
    [[ $result == 'tls-pure interop ok'* ]] || { echo "tls-pure client vs pure server ($kind): $result" >&2; exit 1; }
    stop_serve
done
echo "pure server: $served openssl s_client handshakes (3 key kinds x 3 suites x 2 groups) and the pure client, each key kind"
start_serve alpn "$out/ed25519.pem" "$out/ed25519.key"
answer=$(s_client -CAfile "$out/ed25519.pem" -alpn http/1.1,h2)
[[ $answer == *'alpn=h2'* ]] || { echo "tls-pure server ALPN: [$answer] $(head -3 "$out/s_client.err")" >&2; exit 1; }
answer=$(s_client -CAfile "$out/ed25519.pem" -alpn spdy)
[[ $answer != *'pure server'* ]] || { echo "tls-pure server ALPN: a client with no protocol in common was served: [$answer]" >&2; exit 1; }
stop_serve
start_serve auth "$out/ed25519.pem" "$out/ed25519.key" "$out/client-p256.pem"
answer=$(s_client -CAfile "$out/ed25519.pem" -cert "$out/client-p256.pem" -key "$out/client-p256.key")
[[ $answer == *'client=true'* ]] || { echo "tls-pure server client certificate: [$answer] $(head -3 "$out/s_client.err") $(head -3 "$out/serve.log")" >&2; exit 1; }
answer=$(s_client -CAfile "$out/ed25519.pem")
[[ $answer != *'pure server'* ]] || { echo "tls-pure server: a client with no certificate was served: [$answer]" >&2; exit 1; }
answer=$(s_client -CAfile "$out/ed25519.pem" -cert "$out/client-rsa.pem" -key "$out/client-rsa.key")
[[ $answer != *'pure server'* ]] || { echo "tls-pure server: an untrusted client certificate was served: [$answer]" >&2; exit 1; }
stop_serve
echo "pure server: ALPN (server order, none in common refused) and a required client certificate (accepted, absent and untrusted refused)"
# A bulk transfer: a 6 MB file, many records; size and SHA-256 must match (Ed25519, checked in the program).
"$compiler" build tests/cases/tls-pure/bulk.ab -o "$out/bulk" --no-cache
mkdir -p "$out/www"
head -c 6291456 /dev/urandom > "$out/www/big.bin"
expected=$(sha256sum "$out/www/big.bin" | cut -d' ' -f1)
public=$(openssl pkey -in "$out/ed25519.key" -pubout -outform DER | tail -c 32 | od -An -vtx1 | tr -d ' \n')
server_directory="$out/www" start_server ed25519 -HTTP -groups X25519
result=$("$root/tools/run-limited.sh" "$out/bulk" "$port" "$public" /big.bin 6291456 "$expected") || { echo "tls-pure bulk: $result" >&2; head -5 "$out/server.log" >&2; exit 1; }
[[ $result == 'tls-pure bulk ok'* ]] || { echo "tls-pure bulk: $result" >&2; exit 1; }
echo "$result"
stop_server
echo 'tls-pure interop ok'
