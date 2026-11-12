#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/discarded-affine-container
"$compiler" build tests/cases/discarded-affine-container/main.ab -o build/discarded-affine-container/main --fast --no-cache
actual=$(build/discarded-affine-container/main)
expected='I1I2|I1I2|I1I2|I1I2|MI1I2|'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'discarded affine container: got %s\n' "$actual" >&2; exit 1; }
echo 'discarded affine container: ok'
