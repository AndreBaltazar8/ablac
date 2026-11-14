#!/usr/bin/env bash
# The legacy block ciphers of old PKCS#12 files (abla/crypto/legacy: 3DES-CBC and RC2-CBC, decrypt only) against OpenSSL's
# known answers, built --fast and release (#822). The containers that use them, from OpenSSL 1.x, Windows, macOS, Java 8
# and the tax authority's own certificate profile, are checked by tools/test-crypto-encrypted-rsa.sh (cases.txt) and the
# mutual-TLS handshake from one of them by tools/test-tls-unix.sh.
#
# Opt in: AT_TEST_PFX=path/to/TesteWebservices.pfx (AT_TEST_PFX_PASSWORD, default the published TESTEwebservice) reads the AT's
# published web-service test certificate, which is not in this repository: its terms of reuse are the AT's, so each person
# who wants the check downloads it from the AT's "Certificados de segurança" page (see tests/vectors/crypto/encrypted-rsa/README.md).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/crypto-legacy
mkdir -p "$out"
for mode in fast release; do
    flags=()
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/crypto-legacy/main.ab -o "$out/main.$mode" --no-cache ${flags[@]+"${flags[@]}"}
    "$out/main.$mode" | grep -x 'crypto-legacy: ok' > /dev/null || { echo "crypto-legacy ($mode) failed" >&2; exit 1; }
done
if [[ -n ${AT_TEST_PFX:-} ]]; then
    "$compiler" build tests/cases/crypto-legacy/at-identity.ab -o "$out/at-identity" --no-cache
    "$out/at-identity" "$AT_TEST_PFX" "${AT_TEST_PFX_PASSWORD:-TESTEwebservice}"
    echo 'crypto-legacy: the AT test certificate opens'
fi
echo 'crypto-legacy: ok'
