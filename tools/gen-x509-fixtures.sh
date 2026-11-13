#!/usr/bin/env bash
# Regenerates tests/cases/x509/chains (certificates and cases.tsv) with the openssl command line. The output is committed: the
# keys are throwaway and nothing needs this script to run a test; it documents how each chain was made. Every case is
# validated at 2030-01-01T00:00:00Z (1893456000) unless its line says otherwise.
#   cases.tsv: name <TAB> host <TAB> now <TAB> expect (ok, or a text the error holds) <TAB> leaf file <TAB> extra chain files
#   (comma separated) <TAB> trusted roots (comma separated)
set -euo pipefail
out=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/cases/x509/chains}
rm -rf "$out"
mkdir -p "$out"
cd "$out"
serial=100
NOW=1893456000
FROM=20200101000000Z
TO=20400101000000Z

# issue NAME SUBJECT KEY(ec|rsa|ec384) ISSUER(self|name) EXTENSIONS [FROM [TO [HASH]]]
issue() {
    local name=$1 subject=$2 key=$3 issuer=$4 ext=$5 from=${6:-$FROM} to=${7:-$TO} hash=${8:-sha256}
    case $key in
        ec) openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$name.key" 2>/dev/null ;;
        ec384) openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$name.key" 2>/dev/null ;;
        rsa) openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$name.key" 2>/dev/null ;;
        ed25519) openssl genpkey -algorithm ED25519 -out "$name.key" 2>/dev/null ;;
    esac
    local hashflag="-$hash" sigopts=()
    if [[ $key == ed25519 || $hash == none ]]; then hashflag=; fi
    if [[ $hash == pss256 ]]; then hashflag=-sha256; sigopts=(-sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 -sigopt rsa_mgf1_md:sha256); fi
    openssl req -new -key "$name.key" -subj "$subject" -out "$name.csr"
    printf '[ext]\n%s\n' "$ext" > "$name.ext"
    serial=$((serial + 1))
    if [[ $issuer == self ]]; then
        openssl x509 -req -in "$name.csr" -signkey "$name.key" -extfile "$name.ext" -extensions ext -set_serial $serial \
            -not_before "$from" -not_after "$to" $hashflag "${sigopts[@]}" -out "$name.pem" 2>/dev/null
    else
        openssl x509 -req -in "$name.csr" -CA "$issuer.pem" -CAkey "$issuer.key" -extfile "$name.ext" -extensions ext \
            -set_serial $serial -not_before "$from" -not_after "$to" $hashflag "${sigopts[@]}" -out "$name.pem" 2>/dev/null
    fi
}

CA='basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign,cRLSign'
SERVER='basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature
extendedKeyUsage=serverAuth
subjectAltName=DNS:example.com,DNS:www.example.com,DNS:*.wild.example.com,IP:192.0.2.7,IP:2001:db8::1'

issue root-ec "/CN=Test Root EC" ec self "$CA"
issue inter-ec "/CN=Test Intermediate EC" ec root-ec "$CA"
issue leaf-ec "/CN=example.com" ec inter-ec "$SERVER"
issue root-rsa "/CN=Test Root RSA" rsa self "$CA"
issue inter-rsa "/CN=Test Intermediate RSA" rsa root-rsa "$CA"
issue leaf-rsa "/CN=example.com" rsa inter-rsa "$SERVER"
issue inter-ec-under-rsa "/CN=Test Intermediate EC under RSA" ec root-rsa "$CA"
issue leaf-mixed "/CN=example.com" ec inter-ec-under-rsa "$SERVER"
issue root-ed "/CN=Test Root Ed25519" ed25519 self "$CA"
issue inter-ed "/CN=Test Intermediate Ed25519" ed25519 root-ed "$CA"
issue leaf-ed "/CN=example.com" ed25519 inter-ed "$SERVER"
issue leaf-ec-under-ed "/CN=example.com" ec inter-ed "$SERVER"
issue root-pss "/CN=Test Root PSS" rsa self "$CA" "$FROM" "$TO" pss256
issue inter-pss "/CN=Test Intermediate PSS" rsa root-pss "$CA" "$FROM" "$TO" pss256
issue leaf-pss "/CN=example.com" ec inter-pss "$SERVER" "$FROM" "$TO" pss256
issue root-ec384 "/CN=Test Root P-384" ec384 self "$CA"
issue inter-ec384 "/CN=Test Intermediate P-384" ec384 root-ec384 "$CA" "$FROM" "$TO" sha384
issue leaf-ec384 "/CN=example.com" ec384 inter-ec384 "$SERVER" "$FROM" "$TO" sha384
issue leaf-ec-under-ec384 "/CN=example.com" ec inter-ec384 "$SERVER" "$FROM" "$TO" sha384

issue leaf-expired "/CN=example.com" ec inter-ec "$SERVER" 20200101000000Z 20250101000000Z
issue leaf-early "/CN=example.com" ec inter-ec "$SERVER" 20500101000000Z 20600101000000Z
issue leaf-client-only "/CN=example.com" ec inter-ec "basicConstraints=critical,CA:FALSE
extendedKeyUsage=clientAuth
subjectAltName=DNS:example.com"
issue leaf-key-usage "/CN=example.com" ec inter-ec "basicConstraints=critical,CA:FALSE
keyUsage=critical,keyCertSign
subjectAltName=DNS:example.com"
issue leaf-no-san "/CN=example.com" ec inter-ec "basicConstraints=critical,CA:FALSE
extendedKeyUsage=serverAuth"
issue leaf-unknown-critical "/CN=example.com" ec inter-ec "basicConstraints=critical,CA:FALSE
subjectAltName=DNS:example.com
1.2.3.4=critical,ASN1:UTF8String:what"
issue leaf-sha1 "/CN=example.com" rsa inter-rsa "$SERVER" "$FROM" "$TO" sha1 || true
issue leaf-self "/CN=example.com" ec self "$SERVER"
# A CA with name constraints, and what it may and may not issue.
issue inter-constrained "/CN=Constrained Intermediate" ec root-ec "basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign
nameConstraints=critical,permitted;DNS:example.com,excluded;DNS:bad.example.com"
issue leaf-permitted "/CN=ok.example.com" ec inter-constrained "basicConstraints=critical,CA:FALSE
subjectAltName=DNS:ok.example.com"
issue leaf-outside "/CN=other.org" ec inter-constrained "basicConstraints=critical,CA:FALSE
subjectAltName=DNS:other.org"
issue leaf-excluded "/CN=bad.example.com" ec inter-constrained "basicConstraints=critical,CA:FALSE
subjectAltName=DNS:bad.example.com"
issue leaf-excluded-sub "/CN=a.bad.example.com" ec inter-constrained "basicConstraints=critical,CA:FALSE
subjectAltName=DNS:a.bad.example.com"
issue leaf-constrained-ip "/CN=ok.example.com" ec inter-constrained "basicConstraints=critical,CA:FALSE
subjectAltName=DNS:ok.example.com,IP:192.0.2.1"
issue inter-ip-constrained "/CN=IP Constrained Intermediate" ec root-ec "basicConstraints=critical,CA:TRUE
keyUsage=critical,keyCertSign
nameConstraints=critical,permitted;IP:192.0.2.0/255.255.255.0"
issue leaf-ip-in "/CN=ip" ec inter-ip-constrained "basicConstraints=critical,CA:FALSE
subjectAltName=IP:192.0.2.9"
issue leaf-ip-out "/CN=ip" ec inter-ip-constrained "basicConstraints=critical,CA:FALSE
subjectAltName=IP:198.51.100.9"
# Path length: root, inter (pathlen 0), another CA below it, the leaf.
issue inter-pathlen0 "/CN=Pathlen Zero" ec root-ec "basicConstraints=critical,CA:TRUE,pathlen:0
keyUsage=critical,keyCertSign"
issue inter-below "/CN=Below Pathlen Zero" ec inter-pathlen0 "$CA"
issue leaf-deep "/CN=example.com" ec inter-below "$SERVER"
issue leaf-pathlen-ok "/CN=example.com" ec inter-pathlen0 "$SERVER"
issue inter-not-ca "/CN=Not A CA" ec root-ec "basicConstraints=critical,CA:FALSE"
issue leaf-under-not-ca "/CN=example.com" ec inter-not-ca "$SERVER"
issue inter-no-cert-sign "/CN=No certSign" ec root-ec "basicConstraints=critical,CA:TRUE
keyUsage=critical,digitalSignature"
issue leaf-under-no-cert-sign "/CN=example.com" ec inter-no-cert-sign "$SERVER"
issue inter-eku-client "/CN=Client Only CA" ec root-ec "basicConstraints=critical,CA:TRUE
extendedKeyUsage=clientAuth"
issue leaf-under-eku-client "/CN=example.com" ec inter-eku-client "$SERVER"
# A leaf signed by an intermediate that is not the one the chain carries: its signature does not verify.
issue other-key-ec "/CN=Test Intermediate EC" ec root-ec "$CA"

# Tamper with the signature: the last signature byte changes, the structure does not.
openssl x509 -in leaf-ec.pem -outform DER -out leaf-ec.der
size=$(stat -c %s leaf-ec.der)
{ head -c $((size - 1)) leaf-ec.der; printf "\\x$(printf %02x $(( $(tail -c 1 leaf-ec.der | od -An -tu1) ^ 1 )))"; } > leaf-bad-signature.der
openssl x509 -inform DER -in leaf-bad-signature.der -out leaf-bad-signature.pem 2>/dev/null || {
    echo "tampered certificate does not parse in openssl" >&2; exit 1; }
rm -f leaf-ec.der leaf-bad-signature.der

cat inter-ec.pem inter-rsa.pem root-ec.pem > noise-chain.pem

{
printf 'good-ec\texample.com\t%s\tok\tleaf-ec.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'good-ec-www\twww.example.com\t%s\tok\tleaf-ec.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'good-ec-uppercase-host\tEXAMPLE.COM.\t%s\tok\tleaf-ec.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'good-ec-no-host-check\t\t%s\tok\tleaf-ec.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'good-rsa\texample.com\t%s\tok\tleaf-rsa.pem\tinter-rsa.pem\troot-rsa.pem\n' $NOW
printf 'good-mixed\texample.com\t%s\tok\tleaf-mixed.pem\tinter-ec-under-rsa.pem\troot-rsa.pem\n' $NOW
printf 'good-p384\texample.com\t%s\tok\tleaf-ec384.pem\tinter-ec384.pem\troot-ec384.pem\n' $NOW
printf 'good-p256-under-p384\texample.com\t%s\tok\tleaf-ec-under-ec384.pem\tinter-ec384.pem\troot-ec384.pem\n' $NOW
printf 'good-ed25519\texample.com\t%s\tok\tleaf-ed.pem\tinter-ed.pem\troot-ed.pem\n' $NOW
printf 'good-ec-under-ed25519\texample.com\t%s\tok\tleaf-ec-under-ed.pem\tinter-ed.pem\troot-ed.pem\n' $NOW
printf 'good-rsa-pss\texample.com\t%s\tok\tleaf-pss.pem\tinter-pss.pem\troot-pss.pem\n' $NOW
printf 'good-noisy-chain\texample.com\t%s\tok\tleaf-ec.pem\tnoise-chain.pem\troot-ec.pem\n' $NOW
printf 'wrong-host\tother.com\t%s\tnot valid for the host name\tleaf-ec.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'wildcard-match\ta.wild.example.com\t%s\tok\tleaf-ec.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'wildcard-bare\twild.example.com\t%s\tnot valid for the host name\tleaf-ec.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'wildcard-two-labels\ta.b.wild.example.com\t%s\tnot valid for the host name\tleaf-ec.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'ip-v4\t192.0.2.7\t%s\tok\tleaf-ec.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'ip-v4-other\t192.0.2.8\t%s\tnot valid for the host name\tleaf-ec.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'ip-v6\t2001:db8::1\t%s\tok\tleaf-ec.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'ip-v6-other\t2001:db8::2\t%s\tnot valid for the host name\tleaf-ec.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'expired\texample.com\t%s\thas expired\tleaf-expired.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'not-yet-valid\texample.com\t%s\tnot yet valid\tleaf-early.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'before-validity\texample.com\t1500000000\tnot yet valid\tleaf-ec.pem\tinter-ec.pem\troot-ec.pem\n'
printf 'wrong-usage\texample.com\t%s\tnot valid for this purpose\tleaf-client-only.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'wrong-key-usage\texample.com\t%s\tkey usage\tleaf-key-usage.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'no-san\texample.com\t%s\thas no subjectAltName for example.com\tleaf-no-san.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'unknown-critical-extension\texample.com\t%s\tcritical extension\tleaf-unknown-critical.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'missing-intermediate\texample.com\t%s\tunknown authority\tleaf-ec.pem\t\troot-ec.pem\n' $NOW
printf 'wrong-root\texample.com\t%s\tunknown authority\tleaf-ec.pem\tinter-ec.pem\troot-rsa.pem\n' $NOW
printf 'no-roots\texample.com\t%s\tunknown authority\tleaf-ec.pem\tinter-ec.pem\t\n' $NOW
printf 'self-signed-untrusted\texample.com\t%s\tunknown authority\tleaf-self.pem\t\troot-ec.pem\n' $NOW
printf 'self-signed-trusted\texample.com\t%s\tok\tleaf-self.pem\t\tleaf-self.pem\n' $NOW
printf 'bad-signature\texample.com\t%s\tsignature\tleaf-bad-signature.pem\tinter-ec.pem\troot-ec.pem\n' $NOW
printf 'wrong-intermediate-key\texample.com\t%s\tunknown authority\tleaf-ec.pem\tother-key-ec.pem\troot-ec.pem\n' $NOW
printf 'name-constraint-permitted\tok.example.com\t%s\tok\tleaf-permitted.pem\tinter-constrained.pem\troot-ec.pem\n' $NOW
printf 'name-constraint-outside\tother.org\t%s\tname constraints\tleaf-outside.pem\tinter-constrained.pem\troot-ec.pem\n' $NOW
printf 'name-constraint-excluded\tbad.example.com\t%s\tname constraints\tleaf-excluded.pem\tinter-constrained.pem\troot-ec.pem\n' $NOW
printf 'name-constraint-excluded-subdomain\ta.bad.example.com\t%s\tname constraints\tleaf-excluded-sub.pem\tinter-constrained.pem\troot-ec.pem\n' $NOW
printf 'name-constraint-other-type-unconstrained\tok.example.com\t%s\tok\tleaf-constrained-ip.pem\tinter-constrained.pem\troot-ec.pem\n' $NOW
printf 'name-constraint-ip-in\t192.0.2.9\t%s\tok\tleaf-ip-in.pem\tinter-ip-constrained.pem\troot-ec.pem\n' $NOW
printf 'name-constraint-ip-out\t198.51.100.9\t%s\tname constraints\tleaf-ip-out.pem\tinter-ip-constrained.pem\troot-ec.pem\n' $NOW
printf 'path-length-exceeded\texample.com\t%s\tpath length\tleaf-deep.pem\tinter-below.pem,inter-pathlen0.pem\troot-ec.pem\n' $NOW
printf 'path-length-ok\texample.com\t%s\tok\tleaf-pathlen-ok.pem\tinter-pathlen0.pem\troot-ec.pem\n' $NOW
printf 'intermediate-not-ca\texample.com\t%s\tnot a CA\tleaf-under-not-ca.pem\tinter-not-ca.pem\troot-ec.pem\n' $NOW
printf 'intermediate-no-cert-sign\texample.com\t%s\tsign certificates\tleaf-under-no-cert-sign.pem\tinter-no-cert-sign.pem\troot-ec.pem\n' $NOW
printf 'intermediate-eku-client\texample.com\t%s\tnot valid for this purpose\tleaf-under-eku-client.pem\tinter-eku-client.pem\troot-ec.pem\n' $NOW
} > cases.tsv
if [[ -f leaf-sha1.pem ]]; then
    printf 'sha1-signature\texample.com\t%s\tSHA-1\tleaf-sha1.pem\tinter-rsa.pem\troot-rsa.pem\n' $NOW >> cases.tsv
fi
rm -f *.key *.csr *.ext
echo "wrote $(ls *.pem | wc -l) certificates and $(wc -l < cases.tsv) cases in $out"
