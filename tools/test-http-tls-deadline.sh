#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/http-tls-deadline"
mkdir -p "$out"
rm -f "$out/ready"
cp "$root/tests/vectors/crypto/test-keys/tls-server.pem" "$out/key.pem"
openssl req -x509 -new -key "$out/key.pem" -days 2 -subj /CN=localhost \
    -out "$out/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$out/key.pem" -in "$out/cert.pem" \
    -passout pass:test -out "$out/identity.p12" 2>/dev/null
# The peer is an Abla program over a raw TCP socket (no TLS library, no shared code with
# the client): it never completes a handshake, stalling or trickling bytes. The client
# under test is the hosted (OpenSSL) HTTPS client of abla/http/tls with a 250 ms deadline.
"$compiler" build "$root/tests/cases/http-tls-deadline-peer/peer.ab" -o "$out/peer" --fast --no-cache
peer_pid=
trap 'if [[ -n $peer_pid ]]; then kill "$peer_pid" 2>/dev/null || true; wait "$peer_pid" 2>/dev/null || true; fi' EXIT
# run_client [peer argument]: start a peer (hard timeout 60 s), build the client for its
# port and set status to the client's exit status; the peer is stopped afterwards.
run_client() {
    rm -f "$out/ready"
    timeout 60 "$out/peer" "$out/ready" "$@" &
    peer_pid=$!
    for _ in $(seq 1 500); do [[ -e $out/ready ]] && break; sleep 0.02; done
    [[ -e $out/ready ]] || { echo 'HTTPS handshake deadline: the peer did not publish its port' >&2; exit 1; }
    port=$(cat "$out/ready")
    sed -e "s|CERTFILE|$out/cert.pem|g" -e "s|KEYFILE|$out/key.pem|g" \
        -e "s|P12FILE|$out/identity.p12|g" -e "s/39093/$port/g" \
        "$root/tests/cases/http-tls-deadline/main.ab" > "$out/main.ab"
    # (Release mode: the control below needs a client that fails far inside 100 ms, which a handshake attempt of an
    # unoptimised build does not on a slow machine.)
    "$compiler" build "$out/main.ab" -o "$out/main" --no-cache
    status=0
    "$out/main" || status=$?
    kill "$peer_pid" 2>/dev/null || true
    wait "$peer_pid" 2>/dev/null || true
    peer_pid=
}
# Control: a peer that closes at once ends every exchange far inside the expected window.
run_client immediate
[[ $status -ne 42 ]] || { echo 'HTTPS handshake deadline: the client passed against a peer that closes at once' >&2; exit 1; }
run_client
[[ $status -eq 42 ]]
echo 'HTTPS handshake deadline: plain, PEM and PKCS12 passed'
