#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/programmable-build"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/program-build/program-root.ab" \
    -o "$output_directory/program-root" --fast
"$compiler" build \
    "$project_root/tests/cases/program-build/generated-root.ab" \
    -o "$output_directory/generated-root" --fast --no-cache
"$compiler" build \
    "$project_root/tests/cases/program-build/artifacts-root.ab" \
    -o "$output_directory/artifacts-root" --fast --no-cache
"$compiler" build \
    "$project_root/tests/cases/program-build/exported-scalar-only.ab" \
    --emit shared-library -o "$output_directory/libabla_scalar.so" \
    --fast --no-cache

set +e
"$output_directory/program-root"
root_status=$?
"$output_directory/program-child"
child_status=$?
"$output_directory/program-grandchild"
grandchild_status=$?
"$output_directory/generated-root"
generated_root_status=$?
"$output_directory/generated-child"
generated_child_status=$?
"$output_directory/artifacts-root"
artifacts_root_status=$?
set -e

[[ $root_status -eq 40 ]]
[[ $child_status -eq 41 ]]
[[ $grandchild_status -eq 42 ]]
[[ $generated_root_status -eq 39 ]]
[[ $generated_child_status -eq 43 ]]
[[ $artifacts_root_status -eq 38 ]]

if grep -q '@abla.exports.initialized' \
    "$output_directory/libabla_scalar.so.ll"; then
    echo "constant scalar globals retained the lazy export guard" >&2
    exit 1
fi
clang "$project_root/tests/cases/program-build/export-scalar-caller.c" \
    -L"$output_directory" -Wl,-rpath,"$output_directory" -labla_scalar \
    -o "$output_directory/export-scalar-caller"
"$output_directory/export-scalar-caller"

llvm-readelf -h "$output_directory/program.o" | grep -q 'REL (Relocatable file)'
llvm-ar t "$output_directory/libprogram.a" | grep -q '.o$'
llvm-readelf -h "$output_directory/libabla_app.so" | \
    grep -q 'DYN (Shared object file)'
llvm-nm -D --defined-only "$output_directory/libabla_app.so" | \
    grep -q ' abla_app_answer$'
llvm-nm -D --defined-only "$output_directory/libabla_app.so" | \
    grep -q ' abla_app_next$'
llvm-nm -D --defined-only "$output_directory/libabla_app.so" | \
    grep -q ' abla_app_resource_next$'
llvm-nm -D --defined-only "$output_directory/libabla_app.so" | \
    grep -q ' abla_app_add$'
llvm-nm -D --defined-only "$output_directory/libabla_app.so" | \
    grep -q ' abla_app_i8_identity$'
llvm-nm -D --defined-only "$output_directory/libabla_app.so" | \
    grep -q ' abla_app_u64_identity$'
llvm-nm -D --defined-only "$output_directory/libabla_app.so" | \
    grep -q ' abla_app_bytes_score$'
llvm-nm -D --defined-only "$output_directory/libabla_app.so" | \
    grep -q ' abla_app_bytes_length$'
llvm-nm -D --defined-only "$output_directory/libabla_app.so" | \
    grep -q ' abla_app_echo_bytes$'
llvm-nm -D --defined-only "$output_directory/libabla_app.so" | \
    grep -q ' abla_app_invoke$'
llvm-nm -D --defined-only "$output_directory/libabla_app.so" | \
    grep -q ' abla_app_checked_divide$'
llvm-nm -D --defined-only "$output_directory/libabla_app.so" | \
    grep -q ' abla_owned_bytes_release$'
if llvm-nm -D --defined-only "$output_directory/libabla_app.so" | \
    grep -q ' abla_global_'; then
    echo "internal Abla global escaped the shared-library ABI" >&2
    exit 1
fi
grep -q '"symbol":"abla_app_add"' \
    "$output_directory/libabla_app.so.abi.json"
grep -q '"name":"value","abi":"i64","ownership":"value"' \
    "$output_directory/libabla_app.so.abi.json"
grep -q '"name":"value","abi":"i8","ownership":"value"' \
    "$output_directory/libabla_app.so.abi.json"
grep -q '"name":"value","abi":"u64","ownership":"value"' \
    "$output_directory/libabla_app.so.abi.json"
grep -q '"name":"value","abi":"bytes","lowering":\["pointer","u64"\],"ownership":"borrowed","calleeAction":"copy"' \
    "$output_directory/libabla_app.so.abi.json"
grep -q '^define i64 @abla_app_bytes_score(ptr' \
    "$output_directory/libabla_app.so.ll"
grep -q 'call void @abla_string_static' \
    "$output_directory/libabla_app.so.ll"
grep -q '"abi":"owned-bytes-handle","ownership":"owned"' \
    "$output_directory/libabla_app.so.abi.json"
grep -q '"release":"abla_owned_bytes_release","releaseExactlyOnce":true' \
    "$output_directory/libabla_app.so.abi.json"
grep -q '"abi":"callback","callingConvention":"c","lowering":\["function-pointer","context-pointer"\]' \
    "$output_directory/libabla_app.so.abi.json"
grep -q '"lifetime":"call","retention":"forbidden","invocation":"synchronous"' \
    "$output_directory/libabla_app.so.abi.json"
grep -q '"panic":"contained","statusAbi":"i32"' \
    "$output_directory/libabla_app.so.abi.json"
grep -q '"panicContainment":"sjlj"' \
    "$output_directory/libabla_app.so.abi.json"
if llvm-nm -D --defined-only "$output_directory/libabla_app.so" | \
    grep -q ' abla_fn_'; then
    echo "internal Abla function symbol escaped the shared-library ABI" >&2
    exit 1
fi
clang "$project_root/tests/cases/program-build/export-caller.c" \
    -L"$output_directory" -Wl,-rpath,"$output_directory" -labla_app \
    -o "$output_directory/export-caller"
"$output_directory/export-caller"

# A graph-producing root must never skip plan evaluation on a native-object
# cache hit. Remove only its requested artifacts and prove a repeated cached
# build recreates the complete nested graph.
rm -f "$output_directory/program-child" \
    "$output_directory/program-grandchild"
"$compiler" build \
    "$project_root/tests/cases/program-build/program-root.ab" \
    -o "$output_directory/program-root" --fast
[[ -x "$output_directory/program-child" ]]
[[ -x "$output_directory/program-grandchild" ]]

set +e
"$compiler" build \
    "$project_root/tests/cases/program-build/invalid-request.ab" \
    -o "$output_directory/invalid-request" --fast --no-cache \
    >"$output_directory/invalid-request.out" \
    2>"$output_directory/invalid-request.err"
invalid_request_status=$?
"$compiler" build \
    "$project_root/tests/cases/program-build/unsupported-artifact.ab" \
    -o "$output_directory/unsupported-artifact" --fast --no-cache \
    >"$output_directory/unsupported-artifact.out" \
    2>"$output_directory/unsupported-artifact.err"
unsupported_artifact_status=$?
set -e

[[ $invalid_request_status -ne 0 ]]
grep -q 'error\[E_BUILD_PROGRAM_REQUEST\]' \
    "$output_directory/invalid-request.err"
[[ $unsupported_artifact_status -ne 0 ]]
grep -q 'error\[E_BUILD_ARTIFACT_UNSUPPORTED\]' \
    "$output_directory/unsupported-artifact.err"

# A later child failure rolls back the whole graph: a pre-existing root
# artifact is restored byte-for-byte and a newly generated source is removed.
printf 'previous-root-artifact\n' >"$output_directory/rollback-root"
rm -f "$output_directory/rollback-generated.ab"
set +e
"$compiler" build \
    "$project_root/tests/cases/program-build/rollback-root.ab" \
    -o "$output_directory/rollback-root" --fast --no-cache \
    >"$output_directory/rollback.out" \
    2>"$output_directory/rollback.err"
rollback_status=$?
set -e
[[ $rollback_status -ne 0 ]]
grep -q '^previous-root-artifact$' "$output_directory/rollback-root"
[[ ! -e $output_directory/rollback-generated.ab ]]
grep -q 'error\[E_EXPORT_SIGNATURE_UNSUPPORTED\]' \
    "$output_directory/rollback.err"

set +e
"$compiler" build \
    "$project_root/tests/cases/program-build/invalid-export.ab" \
    --emit shared-library -o "$output_directory/invalid-export.so" \
    --fast --no-cache >"$output_directory/invalid-export.out" \
    2>"$output_directory/invalid-export.err"
invalid_export_status=$?
"$compiler" build \
    "$project_root/tests/cases/program-build/invalid-callback-export.ab" \
    --emit shared-library -o "$output_directory/invalid-callback-export.so" \
    --fast --no-cache >"$output_directory/invalid-callback-export.out" \
    2>"$output_directory/invalid-callback-export.err"
invalid_callback_export_status=$?
set -e
[[ $invalid_export_status -ne 0 ]]
grep -q 'error\[E_EXPORT_SIGNATURE_UNSUPPORTED\]' \
    "$output_directory/invalid-export.err"
[[ $invalid_callback_export_status -ne 0 ]]
grep -q 'error\[E_EXPORT_SIGNATURE_UNSUPPORTED\]' \
    "$output_directory/invalid-callback-export.err"

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/program-build/program-root.ab" \
    >"$output_directory/emit-build-plan.ll" \
    2>"$output_directory/emit-build-plan.err"
emit_plan_status=$?
set -e
[[ $emit_plan_status -ne 0 ]]
grep -q 'error\[E_BUILD_COMMAND_UNSUPPORTED\]' \
    "$output_directory/emit-build-plan.err"

echo "programmable build: generated/nested programs + object/static/shared artifacts + C ABI export passed"
