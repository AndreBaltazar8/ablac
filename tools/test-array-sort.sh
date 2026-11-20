#!/usr/bin/env bash
# array.sorted / sortedBy and sortedStrings against reference insertion sorts over empty, short, long, sorted, reversed, equal-heavy and random inputs; stability and an unchanged input are checked. Usage: tools/test-array-sort.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/array-sort
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/array-sort/main.ab -o "$out/test" --no-cache
result=$("$out/test") || { echo "array-sort: $result" >&2; exit 1; }
[[ $result == 'array-sort ok'* ]] || { echo "array-sort: $result" >&2; exit 1; }
echo "ok   $result"
