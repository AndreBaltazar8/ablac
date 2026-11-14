#!/usr/bin/env bash
# The legacy and cross-tool PKCS#12 fixtures (#822): every encoding that a client certificate for the tax authority's web
# services (or any other mutual-TLS service) can plausibly arrive in, made by the tools that people use. They hold the
# repository's public test key (and a 4096-bit one made for this directory, a throwaway: the tax authority now wants RSA-4096
# requests) with a self-signed test certificate. NOT credentials. The password is test-only-password unless the name says.
# Re-running changes the salts, so the committed files are the ones the tests read; this script records how they were made.
# Needs OpenSSL 3.x (the legacy provider for RC2/RC4) and, for the Java files, keytool of JDK 8 and JDK 21 (JAVA8_HOME and
# JAVA21_HOME name them; the files are skipped when they are not set).
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
base=$root/tests/vectors/crypto/encrypted-rsa
out=${1:-$base/legacy}
mkdir -p "$out"
key=$root/tests/vectors/crypto/rsa-implicit-key.pem
cert=$base/certificate.pem
pw=test-only-password
p12() { # name, then the openssl pkcs12 -export options
    local name=$1; shift
    openssl pkcs12 -export -inkey "$key" -in "$cert" -name fixture -passout "pass:$pw" "$@" -out "$out/$name.p12"
}
# --- OpenSSL 3, each profile of an old or new writer ---
# What OpenSSL 1.x wrote by default and `openssl pkcs12 -legacy` still writes: RC2-40 certificates, 3DES key, SHA-1 MAC, 2048 rounds.
p12 openssl-1x-default -legacy -iter 2048
# What the tax authority's own test certificate has (read with `openssl pkcs12 -info`): 3DES for key and certificates, SHA-1 MAC, 2000 rounds.
p12 3des-sha1-2000 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -iter 2000
p12 2des-sha1 -legacy -certpbe PBE-SHA1-2DES -keypbe PBE-SHA1-2DES -iter 2048
p12 rc2-128-sha1 -legacy -certpbe PBE-SHA1-RC2-128 -keypbe PBE-SHA1-RC2-128 -iter 2048
p12 rc2-40-sha1 -legacy -certpbe PBE-SHA1-RC2-40 -keypbe PBE-SHA1-RC2-40 -iter 2048
p12 3des-sha256-mac -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha256 -iter 2048
p12 3des-100000 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -iter 100000
# The PBES2 profiles: Windows 10+ (certutil/MMC AES256-SHA256, 2000 rounds), OpenSSL 3's default, other AES sizes, 3DES under PBES2.
p12 aes256-sha256-2000 -certpbe AES-256-CBC -keypbe AES-256-CBC -macalg sha256 -iter 2000
p12 aes192-sha256 -certpbe AES-192-CBC -keypbe AES-192-CBC -macalg sha256 -iter 2048
p12 aes128-sha1-mac -certpbe AES-128-CBC -keypbe AES-128-CBC -macalg sha1 -iter 2048
p12 pbes2-3des -certpbe DES-EDE3-CBC -keypbe DES-EDE3-CBC -macalg sha1 -iter 2048
# A key that is encrypted in a container whose certificates are not, and the other way round.
p12 certs-plain -certpbe NONE -iter 2048
p12 key-plain -keypbe NONE -iter 2048
# Passwords: empty and non-ASCII under the legacy KDF.
openssl pkcs12 -export -legacy -inkey "$key" -in "$cert" -name fixture -iter 2048 -passout pass: -out "$out/legacy-empty-password.p12"
openssl pkcs12 -export -legacy -inkey "$key" -in "$cert" -name fixture -iter 2048 -passout 'pass:tést-only-password' -out "$out/legacy-utf8-password.p12"
# Refused on purpose: SHA-512 and PBMAC1 MACs, RC4 bags.
p12 refused-sha512-mac -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha512 -iter 2048
p12 refused-pbmac1 -pbmac1_pbkdf2 -iter 2048
p12 refused-rc4 -legacy -certpbe PBE-SHA1-RC4-128 -keypbe PBE-SHA1-RC4-128 -iter 2048
# Standalone PKCS#8 under the PKCS#12 PBE schemes (openssl pkcs8 -v1).
openssl pkcs8 -topk8 -in "$key" -v1 PBE-SHA1-RC2-128 -iter 2048 -passout "pass:$pw" -out "$out/pkcs8-rc2-128.pem" -provider legacy -provider default
openssl pkcs8 -topk8 -in "$key" -v1 PBE-SHA1-RC2-40 -iter 2048 -passout "pass:$pw" -out "$out/pkcs8-rc2-40.pem" -provider legacy -provider default
openssl pkcs8 -topk8 -in "$key" -v1 PBE-SHA1-2DES -iter 2048 -passout "pass:$pw" -out "$out/pkcs8-2des.pem" -provider legacy -provider default
# RSA-4096, the size the tax authority's certificates now have, in the profile of its test certificate.
if [[ ! -f $out/key-4096.pem ]]; then
    openssl genrsa -out "$out/key-4096.pem" 4096 2>/dev/null
    openssl req -new -x509 -key "$out/key-4096.pem" -subj /CN=legacy-4096.invalid -days 36500 -sha256 -out "$out/certificate-4096.pem"
fi
openssl pkcs12 -export -inkey "$out/key-4096.pem" -in "$out/certificate-4096.pem" -name fixture -passout "pass:$pw" \
    -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -iter 2000 -out "$out/rsa4096-3des-sha1-2000.p12"
# --- Java's keytool, which rewrites the container in its own profile: JDK 8 to 17 (RC2-40 certificates, 3DES key,
# HmacPBESHA1, 100000 MAC rounds) and JDK 21 (PBES2 AES-256 with HmacSHA256 and HmacPBESHA256, 10000 rounds) ---
for java in 8 21; do
    home_var=JAVA${java}_HOME
    [[ -n ${!home_var:-} ]] || { echo "skipping Java $java ($home_var not set)" >&2; continue; }
    rm -f "$out/java$java.p12"
    "${!home_var}/bin/keytool" -importkeystore -srckeystore "$base/modern.p12" -srcstoretype PKCS12 -srcstorepass "$pw" \
        -destkeystore "$out/java$java.p12" -deststoretype PKCS12 -deststorepass "$pw" -noprompt 2>/dev/null
done
