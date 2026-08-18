#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_root=$project_root/build/floating-point-test

mkdir -p "$output_root"
"$compiler" build \
    "$project_root/tests/cases/modules/floating-point.ab" \
    -o "$output_root/floating-point" --no-cache
set +e
"$output_root/floating-point"
floating_status=$?
set -e
test "$floating_status" -eq 42

"$compiler" build --project \
    "$project_root/tests/cases/floating-native" \
    -o "$output_root/floating-native" --no-cache
set +e
"$output_root/floating-native"
native_status=$?
set -e
test "$native_status" -eq 42
llvm-readelf -d "$output_root/floating-native" |
    rg -q 'Shared library: \[libm'

if "$compiler" build \
    "$project_root/tests/cases/modules/invalid-floating-mixed.ab" \
    -o "$output_root/invalid-mixed" --no-cache \
    >"$output_root/invalid-mixed.stdout" \
    2>"$output_root/invalid-mixed.stderr"; then
    echo 'mixed integer/floating arithmetic unexpectedly compiled' >&2
    exit 1
fi
rg -q 'arithmetic.type' "$output_root/invalid-mixed.stderr"

if "$compiler" build \
    "$project_root/tests/cases/modules/invalid-floating-compile-time.ab" \
    -o "$output_root/invalid-compile-time" --no-cache \
    >"$output_root/invalid-compile-time.stdout" \
    2>"$output_root/invalid-compile-time.stderr"; then
    echo 'compile-time floating evaluation unexpectedly compiled' >&2
    exit 1
fi
rg -q 'float.compile-time.unsupported' \
    "$output_root/invalid-compile-time.stderr"
