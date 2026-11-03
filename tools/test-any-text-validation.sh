#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/any-text-validation"
mkdir -p "$out"
"$compiler" build "$root/tests/cases/any-text/main.ab" -o "$out/main" --fast
status=0
"$out/main" || status=$?
[[ $status -eq 42 ]]
for name in invalid html-invalid attribute-invalid; do
    status=0
    "$compiler" build "$root/tests/cases/any-text/$name.ab" -o "$out/$name" --fast >"$out/$name.log" 2>&1 || status=$?
    [[ $status -ne 0 ]]
    grep -q 'string.interpolation:Item' "$out/$name.log"
done
status=0
"$compiler" build "$root/tests/cases/any-text/variant-invalid.ab" -o "$out/variant-invalid" --fast >"$out/variant-invalid.log" 2>&1 || status=$?
[[ $status -ne 0 ]]
grep -q 'string.interpolation:Choice' "$out/variant-invalid.log"
echo 'known non-printable values rejected by unconditional any-text helpers'
