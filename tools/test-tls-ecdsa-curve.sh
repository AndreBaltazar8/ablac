#!/usr/bin/env bash
# #819 (BoGo ECDSACurveMismatch-Verify-TLS12): tlsVerifySignature takes the curve from the key under TLS 1.2 and from the
# scheme under TLS 1.3. Signatures by openssl over a P-256 and a P-384 key, with the hash a scheme names. Needs openssl.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/tls-ecdsa-curve
rm -rf "$out"
mkdir -p "$out"
command -v openssl > /dev/null || { echo 'tls ecdsa curve: no openssl; skipped'; exit 0; }
for curve in 256 384; do
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-$curve -out "$out/p$curve.key" 2> /dev/null
    openssl req -x509 -new -key "$out/p$curve.key" -out "$out/p$curve.pem" -subj /CN=localhost -days 2 2> /dev/null
done
# TLS 1.2 signs the randoms and the key share; TLS 1.3 signs 64 spaces, a context string, a zero byte and the transcript hash.
head -c 96 /dev/urandom > "$out/content12.bin"
{ printf '%64s' ''; printf 'TLS 1.3, server CertificateVerify\0'; head -c 32 /dev/urandom; } > "$out/content13.bin"
sign() { openssl dgst "-$1" -sign "$out/$2.key" -out "$out/$3.sig" "$out/$4.bin"; }
sign sha256 p384 p384-sha256-12 content12
sign sha384 p256 p256-sha384-12 content12
sign sha256 p384 p384-sha256-13 content13
sign sha256 p256 p256-sha256-13 content13
sign sha384 p384 p384-sha384-13 content13
"$compiler" build tests/cases/tls-pure/ecdsa-curve.ab -o "$out/ecdsa-curve" --no-cache
result=$("$root/tools/run-limited.sh" "$out/ecdsa-curve" "$out") || { printf '%s\n' "$result" >&2; echo 'tls ecdsa curve: failed' >&2; exit 1; }
[[ $result == 'ecdsa curve ok' ]] || { printf '%s\n' "$result" >&2; echo 'tls ecdsa curve: failed' >&2; exit 1; }
echo "$result"
