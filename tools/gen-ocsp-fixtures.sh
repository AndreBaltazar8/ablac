#!/usr/bin/env bash
# Makes tests/cases/ocsp: a test CA, leaf certificates (good, revoked, unknown to the responder, must-staple), responder certificates (delegated, delegated without the
# OCSPSigning extended key usage), another CA, and the OCSP responses and a request that `openssl ocsp` makes for them (tests/cases/ocsp/main.ab reads them; its times come from the
# responses themselves, so they do not age). The keys are made in a temporary directory and not kept. Needs openssl.
#   tools/gen-ocsp-fixtures.sh
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/tests/cases/ocsp
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"
cd "$work"
key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1.key" 2> /dev/null; }
for name in ca other leaf leafmust leafrevoked leafunknown delegate delegatenoeku delegateserver; do key $name; done
openssl req -x509 -new -key ca.key -out ca.pem -subj '/CN=OCSP Test CA' -days 3650 -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign,digitalSignature' 2> /dev/null
openssl req -x509 -new -key other.key -out other.pem -subj '/CN=Other CA' -days 3650 -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign,digitalSignature' 2> /dev/null
issue() { # name serial subject extensions...
    local name=$1 serial=$2 subject=$3
    shift 3
    printf '%s\n' "$@" > "$name.ext"
    openssl req -new -key "$name.key" -subj "$subject" -out "$name.csr" 2> /dev/null
    openssl x509 -req -in "$name.csr" -CA ca.pem -CAkey ca.key -set_serial "$serial" -days 3650 -extfile "$name.ext" -out "$name.pem" 2> /dev/null
}
issue leaf 0x1001 /CN=ocsp.test 'subjectAltName=DNS:ocsp.test' 'extendedKeyUsage=serverAuth'
issue leafmust 0x1002 /CN=must.test 'subjectAltName=DNS:must.test' 'extendedKeyUsage=serverAuth' 'tlsfeature=status_request'
issue leafrevoked 0x1003 /CN=revoked.test 'subjectAltName=DNS:revoked.test' 'extendedKeyUsage=serverAuth'
issue leafunknown 0x1004 /CN=unknown.test 'subjectAltName=DNS:unknown.test' 'extendedKeyUsage=serverAuth'
issue delegate 0x2001 '/CN=OCSP Test Responder' 'keyUsage=digitalSignature' 'extendedKeyUsage=OCSPSigning'
issue delegatenoeku 0x2002 '/CN=OCSP Responder Without EKU' 'keyUsage=digitalSignature'
issue delegateserver 0x2003 "/CN=OCSP Responder With Another EKU" "keyUsage=digitalSignature" "extendedKeyUsage=serverAuth"
# The responder's database: the leaf and the must-staple leaf valid, the third revoked (key compromise), the fourth absent.
{
    printf 'V\t350101000000Z\t\t1001\tunknown\t/CN=ocsp.test\n'
    printf 'V\t350101000000Z\t\t1002\tunknown\t/CN=must.test\n'
    printf 'R\t350101000000Z\t250101000000Z,keyCompromise\t1003\tunknown\t/CN=revoked.test\n'
} > index.txt
request() { openssl ocsp -issuer ca.pem -cert "$1.pem" -reqout "$2.req" -no_nonce 2> /dev/null; }
respond() { # request name, signer, response file, extra options...
    local req=$1 signer=$2 file=$3
    shift 3
    openssl ocsp -index index.txt -CA ca.pem -rsigner "$signer.pem" -rkey "$signer.key" -reqin "$req.req" -respout "$file" -no_nonce "$@" 2> /dev/null
}
request leaf good
request leafmust must
request leafrevoked revoked
request leafunknown unknown
respond good ca good.der -ndays 5
respond good delegate good-delegated.der -ndays 5
respond good delegatenoeku good-delegated-noeku.der -ndays 5
respond good delegateserver good-delegated-servereku.der -ndays 5
respond good other good-other-signer.der -ndays 5
respond good ca good-long.der -ndays 30
respond good ca good-no-next.der
respond must ca good-must.der -ndays 5
respond revoked ca revoked.der -ndays 5
respond unknown ca unknown.der -ndays 5
cp good.req request-good.der
cp request-good.der "$out/request-good.der"
for file in ca.pem other.pem leaf.pem leafmust.pem leafrevoked.pem leafunknown.pem delegate.pem delegatenoeku.pem delegateserver.pem; do cp "$file" "$out/$file"; done
for file in good.der good-delegated.der good-delegated-noeku.der good-delegated-servereku.der good-other-signer.der good-long.der good-no-next.der good-must.der revoked.der unknown.der; do cp "$file" "$out/$file"; done
ls -l "$out" | head -30
