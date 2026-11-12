#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/map-temporary-loop
"$compiler" build tests/cases/map-temporary-loop/main.ab -o build/map-temporary-loop/main --fast --no-cache
actual=$(build/map-temporary-loop/main)
expected='B1B2I1I2|abI1I2|B1B2I1I2|B1B2I1I2I1I2|B1B2I1I2|B1I1I2|B1I1I2|aI1I2|B1I1I2I1I2|B1I1I2|B1I1I2I1I2|B1B2HI1I2|B1HI1I2|B1V1I1|I2B2V2|I2B3V3I3I4|B4V4I4|'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'map temporary loop: got %s\n' "$actual" >&2; exit 1; }
echo 'map temporary loop: ok'
