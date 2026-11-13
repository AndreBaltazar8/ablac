#!/usr/bin/env bash
# abla/tls/pure under structure-aware fuzzing (tools/tls-fuzz/fuzz.ab): a client and a server in one process with an
# attacker between them that changes one record of the handshake per run (cut into pieces, split, joined, its version,
# type, length or a byte changed, truncated, dropped, sent twice, swapped, an alert put before it, or one handshake
# message changed by structure). Harmless changes must still connect, harmful ones must not, and no run may be slow.
# TLS_FUZZ_SEEDS sets how many runs (default 3000), TLS_FUZZ_FIRST the first seed (default 1).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/tls-fuzz
rm -rf "$out"
mkdir -p "$out/certs"
if ! command -v openssl > /dev/null || ! openssl genpkey -algorithm ED25519 -out "$out/certs/ed25519.key" 2> /dev/null; then
    echo "tls-fuzz: needs openssl with Ed25519 to make the certificates" >&2
    exit 1
fi
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/certs/p256.key" 2> /dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$out/certs/rsa.key" 2> /dev/null
for kind in ed25519 p256 rsa; do
    openssl req -x509 -new -key "$out/certs/$kind.key" -out "$out/certs/$kind.pem" -subj /CN=localhost \
        -addext 'subjectAltName=DNS:localhost' -addext 'extendedKeyUsage=serverAuth,clientAuth' -days 2 2> /dev/null
done
"$compiler" build tools/tls-fuzz/fuzz.ab -o "$out/fuzz" --no-cache > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
first=${TLS_FUZZ_FIRST:-1}
seeds=${TLS_FUZZ_SEEDS:-3000}
if "$root/tools/run-limited.sh" "$out/fuzz" "$out/certs" "$first" "$seeds" > "$out/fuzz.log" 2>&1; then
    echo "tls-fuzz ok: $(tail -1 "$out/fuzz.log")"
else
    cat "$out/fuzz.log" | tail -30 >&2
    echo "tls-fuzz: FAILED" >&2
    exit 1
fi
