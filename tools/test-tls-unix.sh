#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out="$root/build/tls-unix"
mkdir -p "$out"
cp tests/vectors/crypto/test-keys/tls-server.pem "$out/key.pem"
openssl req -x509 -new -key "$out/key.pem" -days 2 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost -out "$out/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$out/key.pem" -in "$out/cert.pem" \
    -passout pass:test -out "$out/identity.p12" 2>/dev/null
# Keep pathnames below sockaddr_un's limit even in a deeply nested checkout.
scratch=$(mktemp -d /tmp/abla-tls-unix.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
for profile in fast release; do
    flags=()
    if [[ $profile == fast ]]; then flags+=(--fast); fi
    "$compiler" build tests/cases/tls-unix/main.ab -o "$out/$profile" --no-cache ${flags[@]+"${flags[@]}"}
    python3 tools/test-tls-unix.py "$out/$profile" "$out/cert.pem" "$out/key.pem" "$out/identity.p12" "$scratch"
done
