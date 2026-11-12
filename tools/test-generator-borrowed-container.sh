#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/generator-borrowed-container
"$compiler" build tests/cases/generator-borrowed-container/main.ab -o build/generator-borrowed-container/main --fast --no-cache
actual=$(build/generator-borrowed-container/main)
expected='B1I1I2|B1B2I1I2|B1I1I2|B1I1I2I1I2|B1I1I2|B1B2I1I2|B1I1I2|B1B2I1I2|B1B1I1I2|B1B1I1I2|B1HI1I2|B1||'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'generator borrowed container: got %s\n' "$actual" >&2; exit 1; }
echo 'generator borrowed container: ok'
