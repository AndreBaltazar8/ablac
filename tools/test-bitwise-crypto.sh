#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/bitwise-crypto"
mkdir -p "$output_directory"

set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-bitwise-type.ab" \
    -o "$output_directory/invalid" --no-cache \
    >"$output_directory/invalid-output.txt" \
    2>"$output_directory/invalid-errors.txt"
invalid_status=$?
set -e
if [[ $invalid_status -ne 1 ]] ||
   ! grep -Fq 'bitwise.type' "$output_directory/invalid-errors.txt"; then
    printf '%s\n' 'invalid bitwise operands were not rejected correctly' >&2
    sed -n '1,80p' "$output_directory/invalid-errors.txt" >&2
    exit 1
fi

printf '%s\n' 'bitwise operators: staged/native semantics and type diagnostics passed'
