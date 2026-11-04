#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/http-peer"
mkdir -p "$out"
cd "$root"
cp tests/vectors/crypto/test-keys/tls-server.pem "$out/key.pem"
openssl req -x509 -new -key "$out/key.pem" -days 2 -subj /CN=localhost -out "$out/cert.pem" 2>/dev/null
for mode in fast release; do
    options=()
    [[ $mode == release ]] || options+=(--fast)
    "$compiler" build tests/cases/http-peer/server.ab -o "$out/server" --no-cache "${options[@]}"
    python3 -I tests/cases/http-peer/clients.py "$out/server" "$out/cert.pem" "$out/key.pem"
done
