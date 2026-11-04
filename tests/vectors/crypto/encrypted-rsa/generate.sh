#!/usr/bin/env bash
# All fixtures use the already-public RSA implicit-rejection test key. No real key.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
out=${1:-$root/tests/vectors/crypto/encrypted-rsa}
mkdir -p "$out"
key="$root/tests/vectors/crypto/rsa-implicit-key.pem"
for bits in 128 256; do
    for digest in SHA1 SHA256; do
        lower=$(printf '%s' "$digest" | tr 'A-Z' 'a-z')
        openssl pkcs8 -topk8 -in "$key" -v2 "aes-$bits-cbc" -v2prf "hmacWith$digest" \
            -iter 2048 -passout pass:test-only-password -out "$out/aes$bits-$lower.pem"
    done
done
openssl pkcs8 -topk8 -in "$key" -v2 aes-256-cbc -v2prf hmacWithSHA1 \
    -iter 1 -passout pass: -out "$out/empty-sha1.pem"
openssl pkcs8 -topk8 -in "$key" -v2 aes-128-cbc -v2prf hmacWithSHA256 \
    -iter 1 -passout pass:test-only-password -out "$out/low-count.pem"
long=$(printf '%080d' 0)
openssl pkcs8 -topk8 -in "$key" -v2 aes-256-cbc -v2prf hmacWithSHA1 \
    -iter 17 -passout "pass:$long" -out "$out/long-password.pem"
openssl pkcs8 -topk8 -in "$key" -v2 aes-256-cbc -v2prf hmacWithSHA256 \
    -iter 17 -passout 'pass:tést-only-password' -out "$out/utf8-password.pem"
openssl pkcs8 -topk8 -in "$key" -v1 PBE-SHA1-3DES \
    -passout pass:test-only-password -out "$out/legacy-3des.pem"
