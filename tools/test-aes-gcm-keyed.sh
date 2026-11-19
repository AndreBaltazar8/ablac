#!/usr/bin/env bash
# AES-GCM with a key expanded once (abla/crypto/aes: AesKey.gcmSeal, gcmOpen, what the TLS record layer uses) against the call that expands the key every time: same bytes over
# random keys and lengths, both open each other's records, altered ones refused, hardware and software key schedules; release and --fast. The NIST vectors and what is read
# for constant time are in tools/test-crypto.sh and tools/test-ct.sh.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/aes-gcm-keyed
rm -rf "$out"
mkdir -p "$out"
cd "$root"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/aes-gcm-keyed/main.ab -o "$out/test.$mode" "${flags[@]}"
    result=$("$root/tools/run-limited.sh" "$out/test.$mode" | tail -1) || { echo "aes-gcm keyed ($mode) failed" >&2; exit 1; }
    [[ $result == 'aes-gcm keyed ok' ]] || { echo "aes-gcm keyed ($mode): $result" >&2; exit 1; }
done
echo "ok   AES-GCM with a key expanded once against the per-call expansion, release and --fast"
