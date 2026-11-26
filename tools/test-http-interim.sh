#!/usr/bin/env bash
# 1xx responses above the blocking clients (plain and TLS) and the async one, against a peer written in Abla (tests/cases/http-interim-peer): every HTTP byte is a literal
# in its source. Its TLS side is the pure TLS server; the client under test is the pure HTTPS client of abla/http/tls, so both ends of the TLS
# case are OpenSSL (what the case checks is the handling of 1xx responses above TLS). The plain and async cases use no TLS at all.
# Every step's output goes to a log under build/http-interim and is printed when the step fails: a failure of this test says what failed. The peer picks its own ports (port 0) and
# publishes them in a file written atomically, which this script waits for (and for the peer to still be alive); the client program is built once, before the peer starts, and
# takes the ports as arguments, so nothing here depends on how long a build takes on a loaded machine.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/http-interim"
rm -rf "$out"
mkdir -p "$out"
# The clients trust the test certificate through SSL_CERT_FILE. Nixpkgs' OpenSSL
# reads NIX_SSL_CERT_FILE before it, and a Nix install sets that to the system
# bundle (CI does), so it would not see the certificate.
unset NIX_SSL_CERT_FILE

step() {   # step NAME COMMAND...: runs it with its output in $out/NAME.log, which is printed when it fails
    local name=$1
    shift
    "$@" > "$out/$name.log" 2>&1 || {
        local status=$?
        echo "HTTP interim: $name failed (exit $status): $*" >&2
        cat "$out/$name.log" >&2
        exit 1
    }
}

cp "$root/tests/vectors/crypto/test-keys/tls-server.pem" "$out/key.pem"
step certificate openssl req -x509 -new -key "$out/key.pem" -days 2 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost,IP:127.0.0.1 -out "$out/cert.pem"
step build-peer "$compiler" build "$root/tests/cases/http-interim-peer/peer.ab" -o "$out/peer" --fast
step build-client "$compiler" build "$root/tests/cases/http-interim/main.ab" -o "$out/main" --fast

peer_pid=
trap 'if [[ -n $peer_pid ]]; then kill "$peer_pid" 2>/dev/null || true; wait "$peer_pid" 2>/dev/null || true; fi' EXIT
# run_client [peer argument...]: starts a peer, waits for its ports, runs the client against it and sets status to the client's exit status; the peer is stopped afterwards.
run_client() {
    rm -f "$out/ready"
    # The peer's hard timeout is long: it only has to outlive the client, which runs at once.
    timeout 600 "$out/peer" "$out/ready" "$out/cert.pem" "$out/key.pem" "$@" > "$out/peer.log" 2>&1 &
    peer_pid=$!
    local ports=
    for _ in $(seq 1 3000); do   # up to 60 s, the machine may be busy
        if [[ -s $out/ready ]]; then
            ports=$(tr -d '\n' < "$out/ready")
            [[ $ports =~ ^[0-9]+\ [0-9]+$ ]] && break
            ports=
        fi
        kill -0 "$peer_pid" 2> /dev/null || break
        sleep 0.02
    done
    if [[ -z $ports ]]; then
        echo "HTTP interim: the peer did not publish its ports (alive: $(kill -0 "$peer_pid" 2> /dev/null && echo yes || echo no)); its log:" >&2
        cat "$out/peer.log" >&2
        exit 1
    fi
    local plain_port=${ports% *} tls_port=${ports#* }
    status=0
    SSL_CERT_FILE="$out/cert.pem" "$out/main" "$plain_port" "$tls_port" > "$out/client.log" 2>&1 || status=$?
    kill "$peer_pid" 2>/dev/null || true
    wait "$peer_pid" 2>/dev/null || true
    peer_pid=
}
# Control: a peer that miscounts /incomplete requests must make the client program fail.
run_client wrong
[[ $status -ne 42 ]] || { echo 'HTTP interim: the client passed against a wrong peer' >&2; exit 1; }
run_client
if [[ $status -ne 42 ]]; then
    echo "HTTP interim: the client exited $status (42 is success); its output:" >&2
    cat "$out/client.log" >&2
    echo "the peer's log:" >&2
    cat "$out/peer.log" >&2
    exit 1
fi
echo 'HTTP interim responses: repeated, split, TLS, async, HEAD and 101 passed'
