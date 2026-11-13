#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
cd "$root"
export ABLA_SYSROOT="$root"
out="$root/build/xtensa-http-stream"
mkdir -p "$out"
"$compiler" build tests/cases/xtensa-http-stream/main.ab --fast --no-cache -o "$out/test"
"$compiler" build tests/cases/xtensa-http-stream/tls.ab --fast --no-cache -o "$out/tls"
test_root=$(mktemp -d "$out/files.XXXXXXXX")
trap 'rm -rf "$test_root"' EXIT
ABLA_HTTP_STREAM_ROOT="$test_root" "$out/test"
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$out/key.pem" -out "$out/cert.pem" \
    -days 2 -subj /CN=localhost -addext subjectAltName=DNS:localhost 2>/dev/null
node tests/cases/xtensa-http-stream/peer.mjs "$out/tls" "$out/cert.pem" "$out/key.pem" "$test_root"
echo 'xtensa-http-stream: bounded framing and loopback TLS passed'
