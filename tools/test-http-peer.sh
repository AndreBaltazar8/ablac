#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/http-peer"
mkdir -p "$out"
cd "$root"
cp tests/vectors/crypto/test-keys/tls-server.pem "$out/key.pem"
openssl req -x509 -new -key "$out/key.pem" -days 2 -subj /CN=localhost -addext subjectAltName=DNS:localhost,IP:127.0.0.1 -out "$out/cert.pem" 2>/dev/null
"$compiler" build tests/cases/http-peer/client.ab -o "$out/client" --fast --no-cache
for mode in fast release; do
    options=()
    [[ $mode == release ]] || options+=(--fast)
    "$compiler" build tests/cases/http-peer/server.ab -o "$out/server" --no-cache ${options[@]+"${options[@]}"}
    bash tests/cases/http-peer/clients.sh "$out/server" "$out/client" "$out/cert.pem" "$out/key.pem"
done
