#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/elvis-field-owner
"$compiler" build tests/cases/elvis-field-owner/main.ab -o build/elvis-field-owner/main --fast --no-cache
actual=$(build/elvis-field-owner/main)
expected='I1B1|I2B2|B4HI4|B5HI5|'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'elvis field owner: %s\n' "$actual" >&2; exit 1; }
echo 'elvis field owner: ok'
