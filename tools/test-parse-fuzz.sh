#!/usr/bin/env bash
# Seeded fuzzing of what parses untrusted bytes in abla/crypto and abla/tls/pure (tools/parse-fuzz/fuzz.ab: DER, X.509, PEM, TLS identities, PKCS#8 and PKCS#12,
# ML-KEM keys and ciphertexts, TLS records, handshake messages, session tickets), with the HPACK/H2Client/H2Server target (tools/http2-fuzz) and the TLS state machines
# (tools/tls-fuzz) run at the same seeds. Each target runs in a release build and a --fast build, and a share of the seeds again with ABLA_GC_STRESS=1 (a collection at every
# safe point: a value that a parser or machine holds without a root is found there). A finding names its seed; `fuzz <target> <seed> 1 <seeds>` repeats it.
#   PARSE_FUZZ_SEEDS   runs per target and build (default 150), PARSE_FUZZ_FIRST the first seed (default 1), PARSE_FUZZ_GC the runs under ABLA_GC_STRESS (default 20)
#   PARSE_FUZZ_TARGETS the targets (default all), PARSE_FUZZ_MODES "release fast" (default both)
# The long campaign runs this per target and mode in fair-flock slots, one run per hold (tools/fuzz-campaign.sh).
# Usage: tools/test-parse-fuzz.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/parse-fuzz
mkdir -p "$out/seeds"
rm -f "$out"/*.log
seeds=${PARSE_FUZZ_SEEDS:-150}
first=${PARSE_FUZZ_FIRST:-1}
gc=${PARSE_FUZZ_GC:-20}
targets=${PARSE_FUZZ_TARGETS:-"der x509 pem identity pkcs mlkem record handshake ticket"}
modes=${PARSE_FUZZ_MODES:-"release fast"}

# Seeds: the repository's own inputs, and certificate-and-key files made here (every key type, PKCS#8 and SEC1, encrypted).
command -v openssl > /dev/null || { echo "parse-fuzz: openssl is needed to make seed keys" >&2; exit 1; }
s="$out/seeds"
if [[ ! -e $s/pair-p256.pem ]]; then
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$s/p256.key" 2> /dev/null
    openssl genpkey -algorithm ED25519 -out "$s/ed25519.key" 2> /dev/null
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$s/rsa.key" 2> /dev/null
    openssl ecparam -name prime256v1 -genkey -noout -out "$s/p256-sec1.key" 2> /dev/null
    openssl ecparam -name secp384r1 -genkey -noout -out "$s/p384-sec1.key" 2> /dev/null
    for kind in p256 ed25519 rsa p256-sec1 p384-sec1; do
        openssl req -x509 -new -key "$s/$kind.key" -out "$s/$kind.crt" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost' -days 2 2> /dev/null
        cat "$s/$kind.crt" "$s/$kind.key" > "$s/pair-$kind.pem"
    done
    openssl pkcs8 -topk8 -in "$s/p256.key" -iter 1 -passout pass:test-only-password -out "$s/p256-encrypted.key" 2> /dev/null
    cat "$s/p256.crt" "$s/p256-encrypted.key" > "$s/pair-p256-encrypted.pem"
fi
seed_files=$(find tests/cases/x509/chains tests/vectors/crypto/encrypted-rsa tests/vectors/crypto/test-keys tests/vectors/crypto/rsa-implicit-key.pem "$s" -type f \( -name '*.pem' -o -name '*.der' -o -name '*.p12' -o -name '*.crt' -o -name '*.key' \) | sort | tr '\n' ' ')

fail=0
build() {   # build MODE: the fuzzer in the mode, into $out/fuzz-MODE
    local mode=$1 flags=()
    [[ $mode == fast ]] && flags=(--fast)
    "$compiler" build tools/parse-fuzz/fuzz.ab -o "$out/fuzz-$mode" --no-cache "${flags[@]}" > "$out/build-$mode.log" 2>&1 || { cat "$out/build-$mode.log" >&2; exit 1; }
}
run() {   # run MODE TARGET COUNT [ENV...]
    local mode=$1 target=$2 count=$3
    shift 3
    if env "$@" "$root/tools/run-limited.sh" "$out/fuzz-$mode" "$target" "$first" "$count" $seed_files > "$out/$target-$mode.log" 2>&1; then
        echo "parse-fuzz $target ($mode${1:+, $1}): $(tail -1 "$out/$target-$mode.log")"
    else
        grep -E 'FINDING|panic' "$out/$target-$mode.log" | head -8 >&2
        echo "parse-fuzz $target ($mode${1:+, $1}): FAILED (log: $out/$target-$mode.log)" >&2
        fail=1
    fi
}
for mode in $modes; do
    build "$mode"
    for target in $targets; do
        run "$mode" "$target" "$seeds" ABLA_FUZZ_NOP=1
        [[ $gc -gt 0 ]] && run "$mode" "$target" "$gc" ABLA_GC_STRESS=1
    done
done
[[ $fail -eq 0 ]] || exit 1
echo "parse-fuzz ok"
