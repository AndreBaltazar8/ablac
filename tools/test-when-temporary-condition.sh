#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/when-temporary-condition
"$compiler" build tests/cases/when-temporary-condition/main.ab -o build/when-temporary-condition/main --fast --no-cache
actual=$(build/when-temporary-condition/main)
expected='HI1C|HI1HI2B|HI3HI1HI3G|HI1A|'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'when temporary condition: got %s\n' "$actual" >&2; exit 1; }
echo 'when temporary condition: ok'
