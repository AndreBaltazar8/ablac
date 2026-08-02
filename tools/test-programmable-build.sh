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
set -e

[[ $root_status -eq 40 ]]
[[ $child_status -eq 41 ]]
[[ $grandchild_status -eq 42 ]]
[[ $generated_root_status -eq 39 ]]
[[ $generated_child_status -eq 43 ]]

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

echo "programmable build: generated source + dynamic child + nested child passed"
