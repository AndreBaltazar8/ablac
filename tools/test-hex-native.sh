#!/usr/bin/env bash
# hexEncode and hexDecode (abla/crypto, run-time paths on native memory) against the code they replaced (tests/cases/hex-native: every byte, every length to 70 and larger, valid and invalid
# decodes, the compile-time evaluator's answers); release and --fast.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/hex-native
rm -rf "$out"
mkdir -p "$out"
cd "$root"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/hex-native/main.ab -o "$out/test.$mode" "${flags[@]}"
    result=$("$root/tools/run-limited.sh" "$out/test.$mode" | tail -1) || { echo "hex-native ($mode) failed" >&2; exit 1; }
    [[ $result == 'hex-native ok' ]] || { echo "hex-native ($mode): $result" >&2; exit 1; }
done
echo "ok   hexEncode and hexDecode against the previous code, release and --fast"
