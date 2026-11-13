#!/usr/bin/env bash
# abla/crypto/p256: RFC 6979's signatures, Wycheproof's ECDSA and ECDH vectors (tests/cases/p256/vectors, parsed with abla/json),
# the operations against each other, and against the openssl command line: keys, signatures and shared secrets each way.
# What is read of the code for constant time is in tools/test-ct.sh.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/p256
rm -rf "$out"
mkdir -p "$out"
chmod 700 "$out"
cd "$root"
"$compiler" build tests/cases/p256/main.ab -o "$out/test" --fast --no-cache
"$out/test" vectors tests/cases/p256/vectors
echo "ok   P-256 known answers, Wycheproof ECDSA and ECDH, round trips"

# --- openssl -----------------------------------------------------------------------------------------------------
printf 'p256 interoperability message' > "$out/message"
spki_header='\x30\x59\x30\x13\x06\x07\x2a\x86\x48\xce\x3d\x02\x01\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07\x03\x42\x00'
for round in 1 2 3; do
    # Ours: a key, a signature and a shared secret checked by openssl.
    "$out/test" key "$out/ours.priv" "$out/ours.pub"
    { printf '\x30\x77\x02\x01\x01\x04\x20'; cat "$out/ours.priv"
      printf '\xa0\x0a\x06\x08\x2a\x86\x48\xce\x3d\x03\x01\x07\xa1\x44\x03\x42\x00'; cat "$out/ours.pub"; } > "$out/ours.der"
    openssl ec -inform DER -in "$out/ours.der" -noout -check 2>/dev/null
    "$out/test" sign "$out/ours.priv" "$out/message" "$out/ours.sig"
    { printf "$spki_header"; cat "$out/ours.pub"; } > "$out/ours.spki"
    openssl pkey -pubin -inform DER -in "$out/ours.spki" -out "$out/ours.pub.pem"
    openssl dgst -sha256 -verify "$out/ours.pub.pem" -signature "$out/ours.sig" "$out/message" > /dev/null
    # openssl's: a key, a signature we verify, a shared secret we agree with.
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/theirs.pem" 2>/dev/null
    openssl pkey -in "$out/theirs.pem" -pubout -outform DER -out "$out/theirs.spki"
    tail -c 65 "$out/theirs.spki" > "$out/theirs.pub"
    openssl dgst -sha256 -sign "$out/theirs.pem" -out "$out/theirs.sig" "$out/message"
    "$out/test" verify "$out/theirs.pub" "$out/message" "$out/theirs.sig"
    "$out/test" ecdh "$out/ours.priv" "$out/theirs.pub" "$out/ours.shared"
    openssl pkeyutl -derive -inkey "$out/theirs.pem" -peerkey "$out/ours.pub.pem" -out "$out/theirs.shared"
    cmp "$out/ours.shared" "$out/theirs.shared"
done
echo "ok   P-256 keys, signatures and shared secrets against openssl, 3 rounds each way"
