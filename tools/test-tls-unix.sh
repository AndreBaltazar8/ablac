#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out="$root/build/tls-unix"
mkdir -p "$out"
cp tests/vectors/crypto/test-keys/tls-server.pem "$out/key.pem"
# macOS's /usr/bin/openssl is LibreSSL, whose PKCS#12 export defaults to
# RC2/3DES; the runtime's OpenSSL 3 can't read that without its legacy
# provider. Prefer Homebrew's OpenSSL 3 and ask for PBES2/AES explicitly.
openssl=openssl
if [[ $(uname -s) == Darwin ]] && command -v brew > /dev/null &&
    [[ -x "$(brew --prefix openssl@3 2> /dev/null)/bin/openssl" ]]; then
    openssl="$(brew --prefix openssl@3)/bin/openssl"
fi
"$openssl" req -x509 -new -key "$out/key.pem" -days 2 -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost -out "$out/cert.pem" 2>/dev/null
"$openssl" pkcs12 -export -inkey "$out/key.pem" -in "$out/cert.pem" \
    -keypbe AES-256-CBC -certpbe AES-256-CBC -macalg sha256 \
    -passout pass:test -out "$out/identity.p12" 2>/dev/null
# The same client identity in the legacy PKCS#12 encoding that the tax authority's own test certificate has (3DES for key and
# certificates, a SHA-1 MAC, 2000 rounds; OpenSSL 1.x and many tools write it): the mutual-TLS handshake must work from it too (#822).
"$openssl" pkcs12 -export -inkey "$out/key.pem" -in "$out/cert.pem" \
    -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -iter 2000 \
    -passout pass:test -out "$out/identity-legacy.p12" 2>/dev/null
# Keep pathnames below sockaddr_un's limit even in a deeply nested checkout.
scratch=$(mktemp -d /tmp/abla-tls-unix.XXXXXX)
trap 'rm -rf "$scratch"' EXIT
for profile in fast release; do
    flags=()
    if [[ $profile == fast ]]; then flags+=(--fast); fi
    "$compiler" build tests/cases/tls-unix/main.ab -o "$out/$profile" --no-cache ${flags[@]+"${flags[@]}"}
    node tests/cases/tls-unix/peer.mjs "$out/$profile" "$out/cert.pem" "$out/key.pem" "$out/identity.p12" "$scratch"
done
node tests/cases/tls-unix/peer.mjs "$out/release" "$out/cert.pem" "$out/key.pem" "$out/identity-legacy.p12" "$scratch"
