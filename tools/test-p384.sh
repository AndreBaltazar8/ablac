#!/usr/bin/env bash
# abla/crypto/p384 on 64-bit limbs (where the target multiplies 64 x 64 -> 128) against the code it replaced (tests/cases/p384/old-p384.ab, on the old 32-bit
# big-number code): public keys, ECDH, RFC 6979 signatures (the same bytes) and verification both ways over random and edge inputs, release and --fast.
# Wycheproof's P-384 ECDSA/ECDH vectors and the openssl interop of the TLS stack run in tools/test-crypto-pure.sh and tools/test-tls-pure-interop.sh;
# what is read of the code for constant time is in tools/test-ct.sh.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/p384
rm -rf "$out"
mkdir -p "$out"
cd "$root"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/p384/reference.ab -o "$out/reference.$mode" "${flags[@]}"
    # The release run takes all 60 random scalars; the --fast one (about thirteen times slower) 20, plus the ten edge scalars: the same code, another code generator.
    reference_arguments=()
    [[ $mode == fast ]] && reference_arguments=(20)
    result=$(ABLA_MAX_SECONDS=1200 "$root/tools/run-limited.sh" "$out/reference.$mode" "${reference_arguments[@]}") || { echo "p384 reference ($mode): $result" >&2; exit 1; }
    [[ $result == 'p384 reference ok' ]] || { echo "p384 reference ($mode): $result" >&2; exit 1; }
done
echo "ok   P-384 against the previous implementation: keys, ECDH, signatures, verification"
