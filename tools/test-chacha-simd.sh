#!/usr/bin/env bash
# ChaCha20 on four blocks at a time (abla/crypto/chacha20poly1305, vectors on x86-64 and AArch64) against the scalar blocks: whole messages against the same in pieces under the
# vector threshold, random keys, nonces, counters (a wrapping one too) and lengths up to 70000; the AEAD against them and refusing altered records; release and --fast. RFC 8439's
# and Wycheproof's vectors are in tools/test-crypto-chacha.sh, what is read for constant time in tools/test-ct.sh.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/chacha-simd
rm -rf "$out"
mkdir -p "$out"
cd "$root"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/chacha-simd/main.ab -o "$out/test.$mode" "${flags[@]}"
    result=$("$root/tools/run-limited.sh" "$out/test.$mode" | tail -1) || { echo "chacha-simd ($mode) failed" >&2; exit 1; }
    [[ $result == 'chacha-simd ok' ]] || { echo "chacha-simd ($mode): $result" >&2; exit 1; }
done
echo "ok   ChaCha20 on vectors against the scalar blocks, release and --fast"
