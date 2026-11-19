#!/usr/bin/env bash
# string.isValidUtf8 (abla/text: an ASCII path eight bytes at a time in front of the intrinsic) against a validator written in the test (RFC 3629): every length up to 40 with one UTF-8
# sequence (valid, overlong, surrogate, too large, truncated, stray continuation) at every offset, so starting and ending anywhere in an eight-byte word, and random strings;
# release and --fast.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/utf8-fast
rm -rf "$out"
mkdir -p "$out"
cd "$root"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/utf8-fast/main.ab -o "$out/test.$mode" "${flags[@]}"
    result=$("$root/tools/run-limited.sh" "$out/test.$mode" | tail -1) || { echo "utf8-fast ($mode) failed" >&2; exit 1; }
    [[ $result == 'utf8-fast ok' ]] || { echo "utf8-fast ($mode): $result" >&2; exit 1; }
done
echo "ok   string.isValidUtf8 against an independent validator, release and --fast"
