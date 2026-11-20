#!/usr/bin/env bash
# The regex engine against the one before its first-byte skip and replace rewrite (tests/cases/regex-diff/old-regex.ab): the same compile results, finds, matches, spans and replacements over many patterns and texts (multi-byte, invalid UTF-8, empty matches, long texts). Usage: tools/test-regex-diff.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/regex-diff
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/regex-diff/main.ab -o "$out/test" --no-cache
result=$("$out/test") || { echo "regex-diff: $result" >&2; exit 1; }
[[ $result == 'regex-diff ok'* ]] || { echo "regex-diff: $result" >&2; exit 1; }
echo "ok   $result"
