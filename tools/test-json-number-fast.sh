#!/usr/bin/env bash
# jsonParse's one-pass integers and shared null/true/false leaves against the general number path (jsonNumberText): every string over a number alphabet up to four bytes and integers around the 18-digit limit, bare, in an array and in an object. Usage: tools/test-json-number-fast.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/json-number-fast
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/json-number-fast/main.ab -o "$out/test" --no-cache
result=$("$out/test") || { echo "json-number-fast: $result" >&2; exit 1; }
[[ $result == 'json-number-fast ok'* ]] || { echo "json-number-fast: $result" >&2; exit 1; }
echo "ok   $result"
