#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/rsa-keygen"
mkdir -p "$out"
chmod 700 "$out"
# Expose the private search helpers only in a generated test-local copy.
sed -e 's/^private trusted fun rsaProbablePrime/trusted fun rsaProbablePrime/' \
    -e 's/^private fun rsaPrimeDistance/fun rsaPrimeDistance/' \
    -e '/^@__abla_trusted_only/d' \
    "$root/stdlib/abla/crypto/rsa/entry.ab" | sed -e 's|^import "raw.ab"$|import "rsa-raw-copy.ab"|' -e 's|^import "../bignum/core.ab"$|import "abla/crypto/bignum/core.ab"|' > "$out/rsa-copy.ab"
# The library's raw.ab names the real entry.ab's types: the copy of it names the copy of entry.ab.
sed -e 's|^import "entry.ab"$|import "rsa-copy.ab"|' -e 's|^import "../bignum/core.ab"$|import "abla/crypto/bignum/core.ab"|' "$root/stdlib/abla/crypto/rsa/raw.ab" > "$out/rsa-raw-copy.ab"
cp "$root/tests/cases/rsa-keygen/primality.ab" "$out/primality.ab"
"$compiler" build "$out/primality.ab" -o "$out/primality" --fast --no-cache --stdlib-internals
"$out/primality"
"$compiler" build "$root/tests/cases/rsa-keygen/main.ab" -o "$out/test" --fast --no-cache
"$out/test" invalid
"$out/test" tail
sizes=(2048)
if [[ ${ABLA_RSA_SLOW_TESTS:-0} == 1 ]]; then sizes+=(3072 4096); fi
for bits in "${sizes[@]}"; do
    timeout 600 "$out/test" "$bits" "$out/key-$bits.pem"
    openssl pkey -in "$out/key-$bits.pem" -check -noout >/dev/null
    openssl pkcs8 -topk8 -nocrypt -in "$out/key-$bits.pem" -outform DER -out "$out/key-$bits.der"
    bash "$root/tests/cases/rsa-keygen/check.sh" "$bits" "$out/key-$bits.der"
    openssl pkey -in "$out/key-$bits.pem" -pubout -out "$out/pub-$bits.pem" 2>/dev/null
    printf 'generated key interoperability' > "$out/message"
    openssl dgst -sha256 -sign "$out/key-$bits.pem" -out "$out/signature" "$out/message"
    openssl dgst -sha256 -verify "$out/pub-$bits.pem" -signature "$out/signature" "$out/message" >/dev/null
    echo "ok   RSA $bits generation, pairwise operations and OpenSSL"
done
