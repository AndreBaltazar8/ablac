#!/usr/bin/env bash
# The Keccak-f[1600] permutation with the lanes in locals (abla/crypto/sha3, sha3PermuteLanes) against the one on words in memory (sha3PermuteWords, what Xtensa runs):
# random, extreme and single-bit states and 2000 chained permutations, release and --fast. The known answers (digests against openssl, ML-KEM's vectors) are in
# tools/test-crypto-pure.sh and what is read of the code for constant time in tools/test-ct.sh.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/sha3-fast
rm -rf "$out"
mkdir -p "$out"
cd "$root"
for mode in release fast; do
    flags=(--no-cache --stdlib-internals)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/sha3-fast/reference.ab -o "$out/reference.$mode" "${flags[@]}"
    result=$("$root/tools/run-limited.sh" "$out/reference.$mode") || { echo "sha3-fast reference ($mode): $result" >&2; exit 1; }
    [[ $result == 'sha3-fast reference ok' ]] || { echo "sha3-fast reference ($mode): $result" >&2; exit 1; }
done
echo "ok   Keccak permutation on lanes in locals against the one on words in memory, release and --fast"
