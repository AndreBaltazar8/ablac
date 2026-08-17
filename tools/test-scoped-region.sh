#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/scoped-region"
mkdir -p "$output_directory"

source_file="$project_root/tests/cases/modules/scoped-region.ab"
"$compiler" --emit-llvm "$source_file" > "$output_directory/program.ll"
# Region begin/end are now ordinary Abla functions. Their LLVM symbols are
# deliberately module-private identities and may also be inlined, so testing
# the retired C ABI names would reject valid all-Abla output. The native probe
# below verifies the stronger property: nested regions restore live bytes,
# run affine drops, and preserve promoted values across the reset boundary.

"$compiler" build "$source_file" -o "$output_directory/program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
native_status=$?
set -e
if [[ $native_status -ne 42 ]]; then
    echo "scoped region: LLVM expected 42, got $native_status" >&2
    exit 1
fi

fixtures=(
    invalid-region-break
    invalid-region-heap-global
    invalid-region-indirect-call
    invalid-region-noescape-effect
    invalid-region-noescape-method-effect
    invalid-region-outer-append
    invalid-region-outer-assignment
    invalid-region-outer-field
    invalid-region-outer-index
    invalid-region-outer-method
    invalid-region-result
    invalid-region-retaining-call
    invalid-region-return
    invalid-region-transitive-call
    invalid-region-transitive-receiver
)

for fixture in "${fixtures[@]}"; do
    output="$output_directory/$fixture"
    rm -f "$output"
    set +e
    "$compiler" build \
        "$project_root/tests/cases/bootstrap/$fixture.ab" \
        -o "$output" >"$output.out" 2>"$output.err"
    status=$?
    set -e
    if [[ $status -ne 1 ]] || ! grep -Fq 'region.' "$output.err"; then
        echo "scoped region: $fixture was not rejected" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]]
done

inferred_output="$output_directory/inferred-noescape-callback"
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-region-noescape-callback-type.ab" \
    -o "$inferred_output"
set +e
"$project_root/tools/run-limited.sh" "$inferred_output"
inferred_status=$?
set -e
if [[ $inferred_status -ne 5 ]]; then
    echo "scoped region: inferred noescape callback expected 5, got $inferred_status" >&2
    exit 1
fi

inferred_lambda_output="$output_directory/inferred-noescape-lambda"
"$compiler" build \
    "$project_root/tests/cases/bootstrap/inferred-noescape-lambda.ab" \
    -o "$inferred_lambda_output"
set +e
"$project_root/tools/run-limited.sh" "$inferred_lambda_output"
inferred_lambda_status=$?
set -e
if [[ $inferred_lambda_status -ne 5 ]]; then
    echo "scoped region: inferred noescape lambda expected 5, got $inferred_lambda_status" >&2
    exit 1
fi

retaining_callback_output="$output_directory/invalid-inferred-retaining-callback"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-inferred-noescape-retaining-callback.ab" \
    -o "$retaining_callback_output" \
    >"$retaining_callback_output.out" \
    2>"$retaining_callback_output.err"
retaining_callback_status=$?
set -e
if [[ $retaining_callback_status -ne 1 ]] ||
    ! grep -Fq 'function.argument:requireNoEscape' \
        "$retaining_callback_output.err"; then
    echo 'scoped region: retaining callback satisfied FnNoEscape inference' >&2
    sed -n '1,80p' "$retaining_callback_output.err" >&2
    exit 1
fi
[[ ! -e $retaining_callback_output ]]

retaining_lambda_output="$output_directory/invalid-inferred-retaining-lambda"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-inferred-noescape-retaining-lambda.ab" \
    -o "$retaining_lambda_output" \
    >"$retaining_lambda_output.out" \
    2>"$retaining_lambda_output.err"
retaining_lambda_status=$?
set -e
if [[ $retaining_lambda_status -ne 1 ]] ||
    ! grep -Fq 'function.argument:requireNoEscape' \
        "$retaining_lambda_output.err"; then
    echo 'scoped region: retaining lambda satisfied FnNoEscape inference' >&2
    sed -n '1,80p' "$retaining_lambda_output.err" >&2
    exit 1
fi
[[ ! -e $retaining_lambda_output ]]

retaining_lambda_store_output="$output_directory/invalid-inferred-retaining-lambda-store"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-inferred-noescape-retaining-lambda-store.ab" \
    -o "$retaining_lambda_store_output" \
    >"$retaining_lambda_store_output.out" \
    2>"$retaining_lambda_store_output.err"
retaining_lambda_store_status=$?
set -e
if [[ $retaining_lambda_store_status -ne 1 ]] ||
    ! grep -Fq 'function.argument:requireNoEscape' \
        "$retaining_lambda_store_output.err"; then
    echo 'scoped region: storing lambda satisfied FnNoEscape inference' >&2
    sed -n '1,80p' "$retaining_lambda_store_output.err" >&2
    exit 1
fi
[[ ! -e $retaining_lambda_store_output ]]

retaining_lambda_alias_output="$output_directory/invalid-inferred-retaining-lambda-alias"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-inferred-noescape-retaining-lambda-alias.ab" \
    -o "$retaining_lambda_alias_output" \
    >"$retaining_lambda_alias_output.out" \
    2>"$retaining_lambda_alias_output.err"
retaining_lambda_alias_status=$?
set -e
if [[ $retaining_lambda_alias_status -ne 1 ]] ||
    ! grep -Fq 'function.argument:requireNoEscape' \
        "$retaining_lambda_alias_output.err"; then
    echo 'scoped region: aliased storing lambda satisfied FnNoEscape inference' >&2
    sed -n '1,80p' "$retaining_lambda_alias_output.err" >&2
    exit 1
fi
[[ ! -e $retaining_lambda_alias_output ]]

echo 'scoped region: inferred callback safety + nested LIFO reset + affine drops + compile time + LLVM and available C differential + retention effects passed'
