#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_directory=$project_root/build/tests/nominal-scalars
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/nominal-scalar.ab" \
    -o "$output_directory/nominal-scalar" --no-cache
set +e
"$output_directory/nominal-scalar"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'nominal scalar fixture returned %d, expected 42\n' "$status" >&2
    exit 1
fi

"$compiler" build \
    "$project_root/tests/cases/modules/inferred-nominal-global-method.ab" \
    -o "$output_directory/inferred-nominal-global-method" --no-cache
set +e
"$output_directory/inferred-nominal-global-method"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'inferred nominal global fixture returned %d, expected 42\n' \
        "$status" >&2
    exit 1
fi

"$compiler" build \
    "$project_root/tests/cases/modules/nominal-global-extension-name.ab" \
    -o "$output_directory/nominal-global-extension-name" --no-cache
set +e
"$output_directory/nominal-global-extension-name"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'same-name global/extension fixture returned %d, expected 42\n' \
        "$status" >&2
    exit 1
fi

"$compiler" build \
    "$project_root/tests/cases/modules/module-val-constant.ab" \
    -o "$output_directory/module-val-constant" --no-cache
set +e
"$output_directory/module-val-constant"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'module val constant fixture returned %d, expected 42\n' \
        "$status" >&2
    exit 1
fi

"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/module-val-constant.ab" \
    >"$output_directory/module-val-constant.ll"
grep -Eq '= internal constant i64 42(,|$)' \
    "$output_directory/module-val-constant.ll"
grep -Eq '= internal global i64 0(,|$)' \
    "$output_directory/module-val-constant.ll"

if "$compiler" build \
    "$project_root/tests/cases/modules/invalid-nominal-scalar-conversion.ab" \
    -o "$output_directory/invalid" --no-cache \
    >"$output_directory/invalid.out" 2>"$output_directory/invalid.err"; then
    echo 'implicit underlying-to-nominal conversion unexpectedly compiled' >&2
    exit 1
fi
grep -Fq 'function.argument:usePin' "$output_directory/invalid.err"

"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/nominal-scalar.ab" \
    >"$output_directory/nominal-scalar.ll"
if grep -Eq '%(Pin|Nominal)' "$output_directory/nominal-scalar.ll"; then
    echo 'nominal scalar leaked a wrapper type into LLVM IR' >&2
    exit 1
fi

echo 'nominal scalar typing and zero-cost lowering passed'
