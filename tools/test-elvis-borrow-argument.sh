#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/elvis-borrow-argument
"$compiler" build tests/cases/elvis-borrow-argument/main.ab -o build/elvis-borrow-argument/main --fast --no-cache
actual=$(build/elvis-borrow-argument/main)
expected='B1I1|B2I2|B1I1|B3I3|O1I1|B1I1|B2I2|B1I1|O1I1|O4I4|B1I1|B2I2|'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'elvis borrowed argument: %s\n' "$actual" >&2; exit 1; }
echo 'elvis borrowed argument: ok'
