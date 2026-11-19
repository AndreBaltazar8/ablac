#!/usr/bin/env bash
# jsonStringify's string path (abla/json: the plainness test of a string eight bytes at a time) against an independent escaper written in the test: every length up to 70 with a quote, a
# backslash, a control character, DEL, multi-byte UTF-8 or an invalid byte at every place in an eight-byte word, and random strings; release and --fast.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/json-encode
rm -rf "$out"
mkdir -p "$out"
cd "$root"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/json-encode/main.ab -o "$out/test.$mode" "${flags[@]}"
    result=$("$root/tools/run-limited.sh" "$out/test.$mode" | tail -1) || { echo "json-encode ($mode) failed" >&2; exit 1; }
    [[ $result == 'json-encode ok' ]] || { echo "json-encode ($mode): $result" >&2; exit 1; }
done
echo "ok   jsonStringify's string path against an independent escaper, release and --fast"
