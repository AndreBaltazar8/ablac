#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/default-shadow-helper
ABLA_DEBUG=1 "$compiler" build tests/cases/default-shadow-helper/main.ab -o build/default-shadow-helper/main --fast --no-cache
nm build/default-shadow-helper/main >build/default-shadow-helper/symbols
if ! grep -Fq '__abla_default_value_' build/default-shadow-helper/symbols; then
    echo 'shadowing default did not generate its helper' >&2; exit 1
fi
actual=$(build/default-shadow-helper/main)
expected='HI5F5S|'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'shadowed default helper: got %s\n' "$actual" >&2; exit 1; }
echo 'shadowed default helper: ok'
