#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/ownership-doc-lifetimes
"$compiler" build tests/cases/ownership-doc-lifetimes/main.ab -o build/ownership-doc-lifetimes/main --fast --no-cache
actual=$(build/ownership-doc-lifetimes/main)
expected='B0B1HI2|'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'ownership doc lifetimes: got %s\n' "$actual" >&2; exit 1; }
echo 'ownership doc lifetimes: ok'
