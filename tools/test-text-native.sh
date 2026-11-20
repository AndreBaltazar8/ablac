#!/usr/bin/env bash
# uppercase, lowercase, codePointCount and percentEncode (abla/text, run-time paths on native memory) against the loops they replaced (tests/cases/text-native: every byte, every length to 40, valid and invalid UTF-8
# strings, the query flag, the compile-time evaluator's answers); release and --fast.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$root/build/text-native
rm -rf "$out"
mkdir -p "$out"
cd "$root"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/text-native/main.ab -o "$out/test.$mode" "${flags[@]}"
    result=$("$root/tools/run-limited.sh" "$out/test.$mode" | tail -1) || { echo "text-native ($mode) failed" >&2; exit 1; }
    [[ $result == 'text-native ok' ]] || { echo "text-native ($mode): $result" >&2; exit 1; }
done
echo "ok   uppercase, lowercase, codePointCount and percentEncode against the previous loops, release and --fast"
