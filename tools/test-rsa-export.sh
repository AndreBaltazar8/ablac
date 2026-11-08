#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/rsa-export"
mkdir -p "$out"
chmod 700 "$out"
# Export is private until key generation lands. A test-local copy exposes
# only the helpers under test, without changing the shipped module's API.
sed -e 's/^private @noinline trusted fun rsaPrivateExportDer/trusted fun rsaPrivateExportDer/' \
    -e 's/^private @noinline trusted fun rsaPrivateExportPem/trusted fun rsaPrivateExportPem/' \
    -e 's/^private trusted fun rsaExportLimbs/trusted fun rsaExportLimbs/' \
    "$root/stdlib/abla/crypto/rsa/entry.ab" > "$out/rsa-copy.ab"
# The real module must not expose the export before key generation lands.
cat > "$out/forbidden.ab" <<'ABLA'
import "abla/crypto/rsa"
fun main: int {
    val key = rsaPrivateKeyFromPem("")
    if (rsaPrivateExportDer(key).ok) 0 else 1
}
ABLA
if "$compiler" build "$out/forbidden.ab" -o "$out/forbidden" --fast --no-cache > "$out/forbidden.log" 2>&1; then
    echo 'private RSA export unexpectedly accessible' >&2
    exit 1
fi
rg -q 'name.private:rsaPrivateExportDer|E_NAME_PRIVATE' "$out/forbidden.log"
cp "$root/tests/cases/rsa-export/main.ab" "$out/main.ab"
"$compiler" build "$out/main.ab" -o "$out/main" --fast --no-cache
# This independent OpenSSL-format fixture already has a 2048-bit private key.
cp "$root/tests/vectors/crypto/rsa-implicit-key.pem" "$out/input.pem"
openssl rsa -in "$out/input.pem" -traditional -out "$out/traditional.pem" 2>/dev/null
for input in input traditional; do
    "$out/main" "$out/$input.pem" "$out/$input.der" "$out/$input.out.pem"
    openssl pkcs8 -topk8 -nocrypt -in "$out/$input.pem" -outform DER > "$out/$input.reference.der"
    cmp "$out/$input.der" "$out/$input.reference.der"
    openssl pkey -inform DER -in "$out/$input.der" -check -noout >/dev/null
    openssl pkey -in "$out/$input.out.pem" -check -noout >/dev/null
    openssl pkey -in "$out/$input.pem" -pubout -outform DER > "$out/$input.pub"
    openssl pkey -in "$out/$input.out.pem" -pubout -outform DER > "$out/$input.out.pub"
    cmp "$out/$input.pub" "$out/$input.out.pub"
done
echo 'RSA PKCS8 export: OpenSSL, PKCS1/PKCS8 reimport and absent d passed'
