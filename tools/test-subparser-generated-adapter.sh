#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "$0")/.." && pwd)
output_directory="$project_root/build/subparser-generated-adapter"
source_file="$project_root/tests/cases/modules/subparser-generated-adapter.ab"
mkdir -p "$output_directory"
missing_toolchain_path="$output_directory/missing-toolchain-path"
mkdir -p "$missing_toolchain_path"
ln -sf "$(command -v bash)" "$missing_toolchain_path/bash"
ln -sf "$(command -v readlink)" "$missing_toolchain_path/readlink"
ln -sf "$(command -v dirname)" "$missing_toolchain_path/dirname"
ln -sf "$(command -v timeout)" "$missing_toolchain_path/timeout"
ln -sf "$(command -v prlimit)" "$missing_toolchain_path/prlimit"
ln -sf "$(command -v opt)" "$missing_toolchain_path/opt"

assert_compiler_diagnostic_accounting() {
    local diagnostic_file=$1
    local summary parser extension semantic ir total primary
    summary=$(grep 'compilation failed:' "$diagnostic_file" | tail -n 1)
    read -r parser extension semantic ir total < <(
        sed -E \
            's/.*: ([0-9]+) parser, ([0-9]+) extension, ([0-9]+) semantic, ([0-9]+) IR, ([0-9]+) total.*/\1 \2 \3 \4 \5/' \
            <<<"$summary"
    )
    [[ $((parser + extension + semantic + ir)) -eq $total ]]
    primary=$(grep -c '^error\[' "$diagnostic_file")
    [[ $primary -eq $total ]]
    ! grep -q 'error\[E_NATIVE_TOOLCHAIN\]' "$diagnostic_file"
}

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
    "$project_root/tests/cases/modules/raw-extension-literal.ab" \
    -o "$output_directory/raw-extension-literal-program" --no-cache
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/raw-extension-literal-program"
raw_literal_status=$?
set -e
[[ $raw_literal_status -eq 42 ]]

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-raw-extension-literal.ab" \
    > "$output_directory/invalid-raw-extension-literal.ll" \
    2> "$output_directory/invalid-raw-extension-literal.err"
invalid_raw_literal_status=$?
set -e
[[ $invalid_raw_literal_status -ne 0 ]]
grep -Fq 'error[E_SUBPARSER_FAILURE]: raw literal tag mismatch' \
    "$output_directory/invalid-raw-extension-literal.err"
grep -Fq 'source[extension-expression]:' \
    "$output_directory/invalid-raw-extension-literal.err"
grep -Fq 'source[subparser]:' \
    "$output_directory/invalid-raw-extension-literal.err"

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
    "$project_root/tests/cases/modules/nested-generated-subparser.ab" \
    -o "$output_directory/nested-generated-subparser-program" --no-cache

"$output_directory/nested-generated-subparser-program"

"$compiler" build \
    "$project_root/tests/cases/modules/late-nominal-action.ab" \
    -o "$output_directory/late-nominal-program" --no-cache
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/late-nominal-program"
late_nominal_status=$?
set -e
[[ $late_nominal_status -eq 42 ]]

"$compiler" build \
    "$project_root/tests/cases/modules/cross-late-root.ab" \
    -o "$output_directory/cross-late-program" --no-cache
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/cross-late-program"
cross_late_status=$?
set -e
[[ $cross_late_status -eq 42 ]]

"$compiler" build \
    "$project_root/tests/cases/modules/cross-late-root-reversed.ab" \
    -o "$output_directory/cross-late-reversed-program" --no-cache
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/cross-late-reversed-program"
cross_late_reversed_status=$?
set -e
[[ $cross_late_reversed_status -eq 42 ]]

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
grep -q 'error\[E_EXT_GENERATED_SEMANTIC\]:' \
    "$output_directory/invalid-semantic.err"
grep -q 'source\[generated-origin\]:invalid.semantic:' \
    "$output_directory/invalid-semantic.err"
grep -q '0 parser, 1 extension, 0 semantic, 0 IR, 1 total error' \
    "$output_directory/invalid-semantic.err"
assert_compiler_diagnostic_accounting \
    "$output_directory/invalid-semantic.err"

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-subparser-early-typed-query.ab" \
    > "$output_directory/invalid-early-typed.ll" \
    2> "$output_directory/invalid-early-typed.err"
invalid_early_typed_status=$?
set -e
[[ $invalid_early_typed_status -ne 0 ]]
grep -q 'error\[E_EXT_TYPED_QUERY_BEFORE_RESOLUTION\]:' \
    "$output_directory/invalid-early-typed.err"
grep -q 'context\[subparser\]: `parseEarlyTyped`' \
    "$output_directory/invalid-early-typed.err"
grep -q 'source\[extension-expression\]:' \
    "$output_directory/invalid-early-typed.err"
grep -q '0 parser, 1 extension, 0 semantic, 0 IR, 1 total error' \
    "$output_directory/invalid-early-typed.err"
assert_compiler_diagnostic_accounting \
    "$output_directory/invalid-early-typed.err"

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-generated-request-result.ab" \
    > "$output_directory/invalid-request-result.ll" \
    2> "$output_directory/invalid-request-result.err"
invalid_request_result_status=$?
set -e
[[ $invalid_request_result_status -ne 0 ]]
grep -q 'error\[E_EXT_FINALIZER_RESULT\]:' \
    "$output_directory/invalid-request-result.err"
grep -q 'context\[generated-namespace\]: expected.request.namespace' \
    "$output_directory/invalid-request-result.err"
grep -q 'source\[extension-request\]:' \
    "$output_directory/invalid-request-result.err"
grep -q 'finalizer returned the wrong result kind or namespace' \
    "$output_directory/invalid-request-result.err"
assert_compiler_diagnostic_accounting \
    "$output_directory/invalid-request-result.err"

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-finalizer-function-handle.ab" \
    > "$output_directory/invalid-function-handle.ll" \
    2> "$output_directory/invalid-function-handle.err"
invalid_function_handle_status=$?
set -e
[[ $invalid_function_handle_status -ne 0 ]]
grep -q 'error\[E_EXT_FUNCTION_HANDLE_OUT_OF_RANGE\]:' \
    "$output_directory/invalid-function-handle.err"
grep -q 'compiler API `compilerFunctionName` received invalid function handle 999999' \
    "$output_directory/invalid-function-handle.err"
grep -q 'out of range; expected a compilation-scoped function declaration handle' \
    "$output_directory/invalid-function-handle.err"
grep -q 'context\[generated-extension-finalizer\]: `finalizeInvalidFunctionHandle`' \
    "$output_directory/invalid-function-handle.err"
grep -q 'source\[extension-request\]:invalid.function.handle:' \
    "$output_directory/invalid-function-handle.err"
grep -q '0 parser, 1 extension, 0 semantic, 0 IR, 1 total error' \
    "$output_directory/invalid-function-handle.err"
assert_compiler_diagnostic_accounting \
    "$output_directory/invalid-function-handle.err"

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/bootstrap/invalid-parser-diagnostics.ab" \
    > "$output_directory/invalid-parser.ll" \
    2> "$output_directory/invalid-parser.err"
invalid_parser_status=$?
set -e
[[ $invalid_parser_status -ne 0 ]]
grep -q 'error\[E_PARSE_PARAMETER_SEPARATOR\]:' \
    "$output_directory/invalid-parser.err"
grep -Fq \
    'source[parser]:'"$project_root"'/tests/cases/bootstrap/invalid-parser-diagnostics.ab:' \
    "$output_directory/invalid-parser.err"
grep -q 'error\[E_IR_FUNCTION_VERIFICATION\]:' \
    "$output_directory/invalid-parser.err"
grep -q 'error\[E_IR_EMISSION\]:' \
    "$output_directory/invalid-parser.err"
assert_compiler_diagnostic_accounting \
    "$output_directory/invalid-parser.err"

ABLA_MAX_MEMORY_MB=4096 "$compiler" build \
    "$project_root/tests/cases/modules/ir-diagnostic-fallback.ab" \
    -o "$output_directory/ir-diagnostic-fallback" --no-cache
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/ir-diagnostic-fallback"
ir_diagnostic_status=$?
set -e
[[ $ir_diagnostic_status -eq 42 ]]

set +e
PATH="$missing_toolchain_path" "$compiler" build \
    "$project_root/tests/cases/modules/types-error.ab" \
    -o "$output_directory/invalid-compiler" --no-cache \
    > "$output_directory/invalid-compiler.out" \
    2> "$output_directory/invalid-compiler.err"
invalid_compiler_status=$?
set -e
[[ $invalid_compiler_status -ne 0 ]]
grep -q 'error\[E_SEMANTIC\]:' \
    "$output_directory/invalid-compiler.err"
grep -q '0 parser, 0 extension, 4 semantic, 0 IR, 4 total error' \
    "$output_directory/invalid-compiler.err"
assert_compiler_diagnostic_accounting \
    "$output_directory/invalid-compiler.err"

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-finalizer-function-handle-states.ab" \
    > "$output_directory/invalid-function-handle-states.ll" \
    2> "$output_directory/invalid-function-handle-states.err"
invalid_function_handle_states_status=$?
set -e
[[ $invalid_function_handle_states_status -ne 0 ]]
grep -q 'error\[E_EXT_FUNCTION_HANDLE_UNKNOWN\]:' \
    "$output_directory/invalid-function-handle-states.err"
grep -q 'error\[E_EXT_FUNCTION_HANDLE_WRONG_KIND\]:' \
    "$output_directory/invalid-function-handle-states.err"
grep -q 'error\[E_EXT_FUNCTION_HANDLE_OUT_OF_RANGE\]:' \
    "$output_directory/invalid-function-handle-states.err"

set +e
PATH="$missing_toolchain_path" "$compiler" build \
    "$project_root/tests/cases/bootstrap/block.ab" \
    -o "$output_directory/invalid-native-toolchain" --no-cache \
    > "$output_directory/invalid-native-toolchain.out" \
    2> "$output_directory/invalid-native-toolchain.err"
invalid_native_toolchain_status=$?
set -e
[[ $invalid_native_toolchain_status -ne 0 ]]
grep -q 'error\[E_NATIVE_TOOLCHAIN\]: native toolchain failed with status' \
    "$output_directory/invalid-native-toolchain.err"

"$project_root/tools/test-generated-cross-module-diagnostics.sh" "$compiler"

printf '%s\n' \
    'subparser extension: nested/same-file/cross-module deferred calls + import-order-independent nominal adapters + structured diagnostics + provenance + rollback passed'
