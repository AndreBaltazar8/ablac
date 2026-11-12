#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/when-affine-value
"$compiler" build tests/cases/when-affine-value/main.ab -o build/when-affine-value/main --fast --no-cache
actual=$(build/when-affine-value/main)
expected='I2N|I1I2N|I1M|I1'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'when affine value: got %s\n' "$actual" >&2; exit 1; }
echo 'when affine value: ok'
