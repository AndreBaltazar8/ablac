#!/usr/bin/env bash
# Makes the extra chains of tests/cases/x509 (committed; the keys are thrown away), without regenerating the others:
#   roll-*.pem   a key rollover: roll-root signs roll-1 (subject CN=Roll), whose key signs roll-2 (the same subject: self-issued,
#                not self-signed), and so on to roll-5; roll-leaf (example.com) is signed by roll-4's key (three self-issued certificates in the path), roll-leaf5 by roll-5's (four).
#   mail-*.pem   mail-root signs mail-inter (a CA that permits only the e-mail names of example.com); mail-leaf has the right
#                host name and, in its subject, emailAddress=a@evil.example.org.
set -euo pipefail
out=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/cases/x509/chains}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cd "$work"
serial=2000
CA='basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign'
SERVER='basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:example.com'
# issue NAME SUBJECT ISSUER(self|name) EXTENSIONS
issue() {
    local name=$1 subject=$2 issuer=$3 ext=$4
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$name.key" 2> /dev/null
    openssl req -new -key "$name.key" -subj "$subject" -out "$name.csr"
    printf '[ext]\n%s\n' "$ext" > "$name.ext"
    serial=$((serial + 1))
    if [[ $issuer == self ]]; then
        openssl x509 -req -in "$name.csr" -signkey "$name.key" -extfile "$name.ext" -extensions ext -set_serial $serial \
            -not_before 20200101000000Z -not_after 20400101000000Z -sha256 -out "$name.pem" 2> /dev/null
    else
        openssl x509 -req -in "$name.csr" -CA "$issuer.pem" -CAkey "$issuer.key" -extfile "$name.ext" -extensions ext \
            -set_serial $serial -not_before 20200101000000Z -not_after 20400101000000Z -sha256 -out "$name.pem" 2> /dev/null
    fi
}
issue roll-root "/CN=Roll Root" self "$CA"
issue roll-1 "/CN=Roll" roll-root "$CA"
issue roll-2 "/CN=Roll" roll-1 "$CA"
issue roll-3 "/CN=Roll" roll-2 "$CA"
issue roll-4 "/CN=Roll" roll-3 "$CA"
issue roll-leaf "/CN=example.com" roll-4 "$SERVER"
issue roll-5 "/CN=Roll" roll-4 "$CA"
issue roll-leaf5 "/CN=example.com" roll-5 "$SERVER"
issue mail-root "/CN=Mail Root" self "$CA"
issue mail-inter "/CN=Mail Intermediate" mail-root "$CA
nameConstraints=critical,permitted;email:example.com"
issue mail-leaf "/CN=example.com/emailAddress=a@evil.example.org" mail-inter "$SERVER"
for name in roll-root roll-1 roll-2 roll-3 roll-4 roll-5 roll-leaf roll-leaf5 mail-root mail-inter mail-leaf; do cp "$name.pem" "$out/$name.pem"; done
