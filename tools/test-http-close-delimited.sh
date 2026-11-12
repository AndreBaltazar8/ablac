#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/http-close-delimited"
mkdir -p "$out"
rm -f "$out/ready"
# The clients trust the test certificate through SSL_CERT_FILE. Nixpkgs' OpenSSL
# reads NIX_SSL_CERT_FILE before it, and a Nix install sets that to the system
# bundle (CI does), so it would not see the certificate.
unset NIX_SSL_CERT_FILE
cp "$root/tests/vectors/crypto/test-keys/tls-server.pem" "$out/key.pem"
openssl req -x509 -new -key "$out/key.pem" -days 2 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost,IP:127.0.0.1 \
    -out "$out/cert.pem" 2>/dev/null
# The peer is an Abla program over raw sockets (tests/cases/http-close-delimited-peer):
# every HTTP byte is a literal in its source. Its TLS side is the hosted OpenSSL server
# (abla/tls/hosted); the client under test is the hosted OpenSSL HTTPS client of
# abla/http/tls, so both ends of the TLS cases are OpenSSL (what the cases check is
# the HTTP framing above it, not TLS). The plain and async cases use no TLS at all.
"$compiler" build "$root/tests/cases/http-close-delimited-peer/peer.ab" -o "$out/peer" --fast
peer_pid=
trap 'if [[ -n $peer_pid ]]; then kill "$peer_pid" 2>/dev/null || true; wait "$peer_pid" 2>/dev/null || true; fi' EXIT
# run_client [peer argument...]: start a peer (hard timeout 120 s), build the client for
# its ports and set status to the client's exit status; the peer is stopped afterwards.
run_client() {
    rm -f "$out/ready"
    timeout 120 "$out/peer" "$out/ready" "$out/cert.pem" "$out/key.pem" "$@" &
    peer_pid=$!
    for _ in $(seq 1 500); do [[ -e $out/ready ]] && break; sleep 0.02; done
    [[ -e $out/ready ]] || { echo 'HTTP close-delimited: the peer did not publish its ports' >&2; exit 1; }
    read -r plain_port tls_port < "$out/ready"
    sed -e "s/39092/$plain_port/g" -e "s/39093/$tls_port/g" \
        "$root/tests/cases/http-close-delimited/main.ab" > "$out/main.ab"
    "$compiler" build "$out/main.ab" -o "$out/main" --fast
    status=0
    SSL_CERT_FILE="$out/cert.pem" "$out/main" || status=$?
    kill "$peer_pid" 2>/dev/null || true
    wait "$peer_pid" 2>/dev/null || true
    peer_pid=
}
# Control: a peer that sends a different body must make the client program fail.
run_client wrong
[[ $status -ne 42 ]] || { echo "HTTP close-delimited: the client passed against a wrong peer" >&2; exit 1; }
run_client
[[ $status -eq 42 ]]
echo 'HTTP close-delimited bodies, TLS, async, limits and bodyless responses passed'
