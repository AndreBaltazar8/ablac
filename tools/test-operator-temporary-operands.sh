#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/operator-temporary-operands
"$compiler" build tests/cases/operator-temporary-operands/main.ab -o build/operator-temporary-operands/main --fast --no-cache
actual=$(build/operator-temporary-operands/main)
expected='I1V1|PI3I2V5|PI5I4V9|PI7V13|PI8V14|XI11I10V21|'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'operator temporary operands: got %s\n' "$actual" >&2; exit 1; }
echo 'operator temporary operands: ok'
