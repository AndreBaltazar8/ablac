#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
mkdir -p build/extension-temporary-receiver
"$compiler" build tests/cases/extension-temporary-receiver/main.ab -o build/extension-temporary-receiver/main --fast --no-cache
actual=$(build/extension-temporary-receiver/main)
expected='B1I1|B2I2|C3I3T|B4U4I4|H5I5|H6I6|Q8I8T|H9U9I9|B7|'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'extension temporary receiver: got %s\n' "$actual" >&2; exit 1; }
echo 'extension temporary receiver: ok'
