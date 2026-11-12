#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/elvis-container-loop
"$compiler" build tests/cases/elvis-container-loop/main.ab -o build/elvis-container-loop/main --fast --no-cache
actual=$(build/elvis-container-loop/main)
expected='B1I1B2I2|B3I3B4I4|B1I1I2|B3I3I4|B1I1B2I2|B3I3B4I4|B1I1I2|B3I3I4|B1I1B2I2|I3I4|B3B4|I3I4|'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'elvis container loop: %s\n' "$actual" >&2; exit 1; }
echo 'elvis container loop: ok'
