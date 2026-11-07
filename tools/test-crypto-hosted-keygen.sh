#!/usr/bin/env bash
# abla/crypto/hosted's RSA key generation: sizes, signing and encryption through hosted, round trips through its
# exports, both directions with abla/crypto/rsa (tests/cases/crypto-pure/hosted-keygen.ab), and the generated key
# checked by the openssl CLI. The keys are made for this run and left only in build/crypto-hosted-keygen/keys.
set -uo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=$project_root/build/crypto-hosted-keygen
rm -rf "$out"
mkdir -p "$out/keys"
chmod 700 "$out/keys"
cd "$project_root"

status=0
fail() { echo "FAIL $*"; status=1; }

"$compiler" build tests/cases/crypto-pure/hosted-keygen.ab -o "$out/keygen" --no-cache \
    > "$out/build.log" 2>&1 || { cat "$out/build.log"; exit 2; }
if timeout 900 "$out/keygen" "$out/keys" > "$out/run.log" 2>&1 < /dev/null; then
    echo "ok   hosted keygen: $(tr '\n' ' ' < "$out/run.log")"
else
    fail "hosted keygen (exit $?)"; tail -20 "$out/run.log"
fi

keys=$out/keys
if openssl pkey -in "$keys/hosted.pem" -check -noout > "$out/check.log" 2>&1; then
    echo "ok   openssl accepts the generated key"
else
    fail "openssl check"; cat "$out/check.log"
fi
text=$(openssl pkey -in "$keys/hosted.pem" -text -noout 2>&1)
grep -q 'Private-Key: (2048 bit' <<< "$text" || fail "not 2048 bits"
grep -q 'publicExponent: 65537' <<< "$text" || grep -q 'Exponent: 65537' <<< "$text" || fail "public exponent isn't 65537"
unset text
openssl pkey -inform DER -in "$keys/hosted.der" -out "$keys/from-der.pem" 2>/dev/null &&
    cmp -s "$keys/hosted.pem" "$keys/from-der.pem" || fail "the PEM and DER exports differ"
openssl pkey -in "$keys/hosted.pem" -pubout -out "$keys/openssl-spki.pem" 2>/dev/null &&
    cmp -s "$keys/hosted-spki.pem" "$keys/openssl-spki.pem" || fail "the public export isn't openssl's"
printf 'openssl cross-check' > "$out/message"
openssl dgst -sha256 -sign "$keys/hosted.pem" -out "$out/signature" "$out/message" &&
    openssl dgst -sha256 -verify "$keys/hosted-spki.pem" -signature "$out/signature" "$out/message" > /dev/null ||
    fail "openssl sign and verify with the generated key"

# Key material in a log or in the output would be a leak.
key_text=$(sed -n 2p "$keys/hosted.pem")
if grep -l -F "$key_text" "$out"/*.log > /dev/null 2>&1; then fail "a log holds key material"; fi

[[ $status -eq 0 ]] && echo "crypto-hosted-keygen: ok" || echo "crypto-hosted-keygen: FAILED"
exit "$status"
