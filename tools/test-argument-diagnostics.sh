#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_root=$project_root/build/argument-diagnostics-test

mkdir -p "$output_root"
set +e
"$compiler" build \
    "$project_root/tests/cases/modules/argument-type-error.ab" \
    -o "$output_root/argument-type-error" --no-cache > "$output_root/error.log" 2>&1
status=$?
set -e
test "$status" -ne 0
grep -q 'function.argument:takesInt@[0-9]*:i64:f64' "$output_root/error.log"
grep -q '0 parser, 0 extension, 1 semantic, 0 IR, 1 total error' "$output_root/error.log"
! grep -q 'LLVM verifier' "$output_root/error.log"
echo "argument diagnostics: located semantic error, no verifier noise passed"
