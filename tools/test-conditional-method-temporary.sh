#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/conditional-method-temporary
"$compiler" build tests/cases/conditional-method-temporary/main.ab -o build/conditional-method-temporary/main --fast --no-cache
actual=$(build/conditional-method-temporary/main)
expected='B1I1|I2B2|I2O3I3|I4O4|I4B5I5|I6B6|I6B6|I6S10I10|I11S11|I11B7I7|O9I9|A2|'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'conditional method temporary: got %s\n' "$actual" >&2; exit 1; }
"$compiler" build tests/cases/conditional-method-temporary/lookup.ab -o build/conditional-method-temporary/lookup --fast --no-cache
build/conditional-method-temporary/lookup
echo 'conditional method temporary: ok'
