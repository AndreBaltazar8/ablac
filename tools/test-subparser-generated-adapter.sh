#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "$0")/.." && pwd)
output_directory="$project_root/build/subparser-generated-adapter"
source_file="$project_root/tests/cases/modules/subparser-generated-adapter.ab"
mkdir -p "$output_directory"

"$compiler" --emit-llvm "$source_file" > "$output_directory/first.ll"
"$compiler" --emit-llvm "$source_file" > "$output_directory/second.ll"
cmp "$output_directory/first.ll" "$output_directory/second.ll"
opt --threads=1 -passes=verify -disable-output "$output_directory/first.ll"
"$compiler" build "$source_file" -o "$output_directory/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]]

"$compiler" build \
    "$project_root/tests/cases/modules/subparser-typed-conversion.ab" \
    -o "$output_directory/conversion-program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/conversion-program"
conversion_status=$?
set -e
[[ $conversion_status -eq 42 ]]

"$compiler" build \
    "$project_root/tests/cases/modules/nested-deferred-request.ab" \
    -o "$output_directory/nested-deferred-program" --no-cache
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/nested-deferred-program"
nested_deferred_status=$?
set -e
[[ $nested_deferred_status -eq 42 ]]

"$compiler" build \
    "$project_root/tests/cases/modules/nested-deferred-source-identity.ab" \
    -o "$output_directory/nested-deferred-identity-program" --no-cache
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/nested-deferred-identity-program"
nested_deferred_identity_status=$?
set -e
[[ $nested_deferred_identity_status -eq 42 ]]

"$compiler" build \
    "$project_root/tests/cases/modules/nested-deferred-nominal-action.ab" \
    -o "$output_directory/nested-deferred-nominal-program" --no-cache
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/nested-deferred-nominal-program"
nominal_status=$?
set -e
[[ $nominal_status -eq 42 ]]

"$compiler" build \
    "$project_root/tests/cases/modules/late-nominal-action.ab" \
    -o "$output_directory/late-nominal-program" --no-cache
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/late-nominal-program"
late_nominal_status=$?
set -e
[[ $late_nominal_status -eq 42 ]]

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-resolved-method-builder.ab" \
    > "$output_directory/invalid-builder.ll" \
    2> "$output_directory/invalid-builder.err"
invalid_status=$?
set -e
[[ $invalid_status -ne 0 ]]
grep -q 'LLVM compilation failed:' "$output_directory/invalid-builder.err"

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-generated-export-collision.ab" \
    > "$output_directory/invalid-export.ll" \
    2> "$output_directory/invalid-export.err"
invalid_export_status=$?
set -e
[[ $invalid_export_status -ne 0 ]]
grep -q 'LLVM compilation failed:' "$output_directory/invalid-export.err"

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-generated-ast-semantic.ab" \
    > "$output_directory/invalid-semantic.ll" \
    2> "$output_directory/invalid-semantic.err"
invalid_semantic_status=$?
set -e
[[ $invalid_semantic_status -ne 0 ]]
grep -q 'function.result:' "$output_directory/invalid-semantic.err"
grep -q 'generated.origin:invalid.semantic:' \
    "$output_directory/invalid-semantic.err"

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-subparser-early-typed-query.ab" \
    > "$output_directory/invalid-early-typed.ll" \
    2> "$output_directory/invalid-early-typed.err"
invalid_early_typed_status=$?
set -e
[[ $invalid_early_typed_status -ne 0 ]]
grep -q 'LLVM compilation failed:' \
    "$output_directory/invalid-early-typed.err"

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-generated-request-result.ab" \
    > "$output_directory/invalid-request-result.ll" \
    2> "$output_directory/invalid-request-result.err"
invalid_request_result_status=$?
set -e
[[ $invalid_request_result_status -ne 0 ]]
grep -q 'extension.request:expected.request.namespace:' \
    "$output_directory/invalid-request-result.err"
grep -q 'finalizer returned the wrong result kind or namespace' \
    "$output_directory/invalid-request-result.err"

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-finalizer-function-handle.ab" \
    > "$output_directory/invalid-function-handle.ll" \
    2> "$output_directory/invalid-function-handle.err"
invalid_function_handle_status=$?
set -e
[[ $invalid_function_handle_status -ne 0 ]]
grep -q 'generated-extension finalizer `finalizeInvalidFunctionHandle`' \
    "$output_directory/invalid-function-handle.err"
grep -q 'compiler API `compilerFunctionName` received invalid function handle 999999' \
    "$output_directory/invalid-function-handle.err"
grep -q 'out of range; expected a compilation-scoped function declaration handle' \
    "$output_directory/invalid-function-handle.err"
grep -q 'extension.request:invalid.function.handle:' \
    "$output_directory/invalid-function-handle.err"

printf '%s\n' \
    'subparser extension: nested/late deferred calls + source identity + nominal-result adapters + actionable invalid-handle diagnostics + provenance-carrying AST publication + rollback passed'
