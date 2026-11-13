#!/usr/bin/env bash
# abla/crypto/rsa private keys whose primes differ in size (tests/cases/rsa-unbalanced/keys): they are accepted, sign with PKCS#1
# v1.5 and PSS (openssl verifies) and decrypt OAEP made by openssl. The keys were made from primes drawn with `openssl prime
# -generate` (1024+1025, 1025+1024, 1535+1536, 1536+1537 and 1000+1100 bits), their numbers computed outside the repository and
# checked with `openssl rsa -check`: openssl's own generator does not make a modulus of 2049 bits. The 2049- and 3073-bit ones
# have a modulus whose top byte is 1, which the consistency probe of the importer once overshot (#818).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/rsa-unbalanced
rm -rf "$out"
mkdir -p "$out"
cd "$root"
"$compiler" build tests/cases/rsa-unbalanced/main.ab -o "$out/test" --fast --no-cache
printf 'unbalanced primes message' > "$out/message"
for key in u2049 v2049 u3071 u3073 u2100; do
    pem=tests/cases/rsa-unbalanced/keys/$key.pem
    openssl rsa -in "$pem" -check -noout > /dev/null
    openssl rsa -in "$pem" -pubout -out "$out/$key.pub" 2>/dev/null
    "$out/test" bits "$pem" > "$out/$key.bits"
    [[ $(openssl rsa -in "$pem" -noout -modulus | cut -d= -f2 | wc -c) -gt 1 ]]
    "$out/test" sign "$pem" "$out/message" "$out/$key.pkcs1" "$out/$key.pss"
    openssl dgst -sha256 -verify "$out/$key.pub" -signature "$out/$key.pkcs1" "$out/message" > /dev/null
    openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 -verify "$out/$key.pub" \
        -signature "$out/$key.pss" "$out/message" > /dev/null
    openssl pkeyutl -encrypt -pubin -inkey "$out/$key.pub" -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 \
        -pkeyopt rsa_mgf1_md:sha256 -in "$out/message" -out "$out/$key.ct"
    "$out/test" decrypt "$pem" "$out/$key.ct" "$out/$key.plain"
    cmp "$out/message" "$out/$key.plain"
    echo "ok   RSA $(cat "$out/$key.bits") bits, unbalanced primes: import, PKCS#1 and PSS signatures, OAEP decryption"
done
