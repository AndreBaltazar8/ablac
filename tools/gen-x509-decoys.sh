#!/usr/bin/env bash
# Makes tests/cases/x509/chains/decoys.pem: 70 self-signed certificates with the subject of the chains' intermediate
# ("CN=Test Intermediate EC") and a key of their own each, so every one of them names the leaf's issuer and none of them
# verifies the leaf's signature. tests/cases/x509/main.ab puts them in front of the real intermediate to reach the limit
# of 64 signature checks of the path builder (their subject key identifier is the intermediate's, so the path builder
# does not skip them by key identifier). The output is committed (the keys are thrown away).
set -euo pipefail
out=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/tests/cases/x509/chains/decoys.pem}
chains=$(cd "$(dirname "$out")" && pwd)
ski=$(openssl x509 -in "$chains/inter-ec.pem" -noout -ext subjectKeyIdentifier | tail -1 | tr -d " ")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
: > "$out"
for n in $(seq 1 70); do
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$work/k.pem" 2> /dev/null
    openssl req -new -x509 -key "$work/k.pem" -subj "/CN=Test Intermediate EC" -set_serial $((1000 + n)) \
        -not_before 20200101000000Z -not_after 20400101000000Z \
        -addext "subjectKeyIdentifier=$ski" -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign' -sha256 2> /dev/null >> "$out"
done
grep -c 'BEGIN CERTIFICATE' "$out"
