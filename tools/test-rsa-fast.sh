#!/usr/bin/env bash
# The big-number code behind RSA (abla/crypto/bignum: fused Montgomery multiplication, 64-bit limbs where the target multiplies 64 x 64 -> 128 and the
# limb count is even) against the code it replaced (tests/cases/rsa-fast/old-bignum.ab, unchanged): moduli of 1 to 96 limbs, bit for bit, release and --fast;
# then RSA itself against the openssl command line: keys of 2048 to 4096 bits (and the unbalanced ones of tests/cases/rsa-unbalanced) sign PKCS#1 v1.5 (the same
# bytes as openssl's: the signature is deterministic) and PSS (openssl verifies), and decrypt OAEP made by openssl. Wycheproof's RSA vectors are run by
# tools/test-crypto.sh; what is read of the code for constant time is in tools/test-ct.sh.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/rsa-fast
rm -rf "$out"
mkdir -p "$out"
chmod 700 "$out"
cd "$root"
for mode in release fast; do
    flags=(--no-cache --stdlib-internals)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/rsa-fast/reference.ab -o "$out/reference.$mode" "${flags[@]}"
    # The release run does all the sizes (1 to 96 limbs); the --fast one (about thirty times slower) those to 33: the same code, another code generator.
    reference_arguments=()
    [[ $mode == fast ]] && reference_arguments=(small)
    result=$(ABLA_MAX_SECONDS=1200 "$root/tools/run-limited.sh" "$out/reference.$mode" "${reference_arguments[@]}") || { echo "rsa-fast reference ($mode): $result" >&2; exit 1; }
    [[ $result == 'rsa-fast reference ok' ]] || { echo "rsa-fast reference ($mode): $result" >&2; exit 1; }
done
echo "ok   big-number code against the previous implementation: moduli of 1 to 96 limbs (multiplication, residues, lookup, exponentiation), release and --fast"

"$compiler" build tests/cases/rsa-unbalanced/main.ab -o "$out/test" --no-cache
printf 'rsa-fast interoperability message' > "$out/message"
check_key() {   # check_key PEM LABEL
    local pem=$1 label=$2
    openssl rsa -in "$pem" -pubout -out "$out/key.pub" 2> /dev/null
    "$out/test" sign "$pem" "$out/message" "$out/key.pkcs1" "$out/key.pss"
    openssl dgst -sha256 -sign "$pem" -out "$out/key.openssl" "$out/message"
    cmp "$out/key.pkcs1" "$out/key.openssl"
    openssl dgst -sha256 -sigopt rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 -verify "$out/key.pub" -signature "$out/key.pss" "$out/message" > /dev/null
    openssl pkeyutl -encrypt -pubin -inkey "$out/key.pub" -pkeyopt rsa_padding_mode:oaep -pkeyopt rsa_oaep_md:sha256 \
        -pkeyopt rsa_mgf1_md:sha256 -in "$out/message" -out "$out/key.ct"
    "$out/test" decrypt "$pem" "$out/key.ct" "$out/key.plain"
    cmp "$out/message" "$out/key.plain"
    echo "ok   RSA $label: PKCS#1 v1.5 signature identical to openssl's, PSS verified, OAEP decrypted"
}
for bits in 2048 2560 3072 4096; do
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:$bits -out "$out/key$bits.pem" 2> /dev/null
    check_key "$out/key$bits.pem" "$bits bits"
done
for key in u2049 v2049 u3071 u3073 u2100; do
    # The unbalanced keys (odd limb counts among them): openssl's signature is deterministic here too.
    check_key "tests/cases/rsa-unbalanced/keys/$key.pem" "$key (unbalanced primes)"
done
