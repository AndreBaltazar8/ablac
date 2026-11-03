#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/generic-default"
mkdir -p "$out"
"$compiler" build "$root/tests/cases/generic-default/main.ab" -o "$out/main" --fast
status=0
"$out/main" || status=$?
[[ $status -eq 42 ]]
status=0
"$compiler" build "$root/tests/cases/generic-default/invalid.ab" -o "$out/invalid" --fast >"$out/invalid.log" 2>&1 || status=$?
[[ $status -ne 0 ]]
grep -q 'ownership.move-required:local.*:ticket' "$out/invalid.log"
status=0
"$compiler" build "$root/tests/cases/generic-default/invalid-duplicate.ab" -o "$out/invalid-duplicate" --fast >"$out/invalid-duplicate.log" 2>&1 || status=$?
[[ $status -ne 0 ]]
grep -q 'ownership.move-required:local.*__abla_named_' "$out/invalid-duplicate.log"
echo 'generic constructor defaults preserve affine ownership and non-affine values'
