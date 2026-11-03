#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output="$root/build/affine-default"
mkdir -p "$output"
"$compiler" build "$root/tests/cases/affine-default/main.ab" -o "$output/main" --fast
status=0
"$output/main" || status=$?
[[ $status -eq 42 ]]
status=0
"$compiler" build "$root/tests/cases/affine-default/invalid.ab" -o "$output/invalid" --fast >"$output/invalid.log" 2>&1 || status=$?
[[ $status -ne 0 ]]
grep -q 'ownership.move-required:local.*:ticket' "$output/invalid.log"
echo 'affine named/default arguments move generated temporaries and preserve caller ownership'
