#!/usr/bin/env bash
# Channel bindings of abla/tls/pure (tests/cases/tls-pure/binding.ab): tls-exporter (RFC 9266) and tls-server-end-point
# (RFC 5929), client and server in process. Usage: tools/test-tls-binding.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/tls-binding
rm -rf "$out"
mkdir -p "$out"
command -v openssl > /dev/null || { echo "tls binding: no openssl, skipped"; exit 0; }
openssl genpkey -algorithm ED25519 -out "$out/ed25519.key" 2> /dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/p256.key" 2> /dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$out/p384.key" 2> /dev/null
openssl req -x509 -new -key "$out/ed25519.key" -out "$out/ed25519.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost' -days 2 2> /dev/null
openssl req -x509 -new -key "$out/p256.key" -sha256 -out "$out/p256.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost' -days 2 2> /dev/null
openssl req -x509 -new -key "$out/p384.key" -sha384 -out "$out/p384.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost' -days 2 2> /dev/null
"$compiler" build tests/cases/tls-pure/binding.ab -o "$out/binding" --fast --no-cache > "$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; exit 1; }
result=$("$out/binding" "$out") || { echo "$result" >&2; exit 1; }
[[ $result == "tls binding ok" ]] || { echo "tls binding: $result" >&2; exit 1; }
echo "$result"
