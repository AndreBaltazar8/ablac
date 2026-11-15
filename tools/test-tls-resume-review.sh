#!/usr/bin/env bash
# Regression cases from the review of TLS 1.3 resumption (tests/cases/tls-pure/resume-review.ab): a ticket bound to how
# the server was verified (R1), and a second ClientHello that drops a PSK the HelloRetryRequest's suite made unusable (R2).
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/tls-resume-review
rm -rf "$out"
mkdir -p "$out"
command -v openssl > /dev/null || { echo "tls resume review: no openssl, skipped"; exit 0; }
openssl genpkey -algorithm ED25519 -out "$out/ed25519.key" 2> /dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/p256.key" 2> /dev/null
for kind in ed25519 p256; do
    openssl req -x509 -new -key "$out/$kind.key" -out "$out/$kind.pem" -subj /CN=localhost \
        -addext 'subjectAltName=DNS:localhost' -days 2 2> /dev/null
done
"$compiler" build tests/cases/tls-pure/resume-review.ab -o "$out/review" --fast --no-cache > "$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; exit 1; }
"$out/review" "$out"
