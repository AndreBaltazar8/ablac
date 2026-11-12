#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/exit-temporary-defer
"$compiler" build tests/cases/exit-temporary-defer/main.ab -o build/exit-temporary-defer/main --fast --no-cache
actual=$(build/exit-temporary-defer/main)
expected='HI1D|HI2NO|NHI7O|DLHI3|HI4D0HI5D1|'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'exit temporary/defer: got %s\n' "$actual" >&2; exit 1; }
echo 'exit temporary/defer: ok'
