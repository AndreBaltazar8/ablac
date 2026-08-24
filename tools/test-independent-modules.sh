#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/independent-module-test"
root_output="$output_directory/root"
child_output="$project_root/build/independent-module"
generated_entry="$project_root/build/.abla-independent/independent-module.abla-independent.ab"
mkdir -p "$output_directory"

build_independent() {
    "$compiler" build \
        "$project_root/tests/cases/program-build/independent-module.ab" \
        -o "$root_output" --fast
}

build_independent
first_child_identity=$(sha256sum "$child_output" | cut -d' ' -f1)
build_independent
second_child_identity=$(sha256sum "$child_output" | cut -d' ' -f1)
[[ $first_child_identity == "$second_child_identity" ]]

set +e
"$root_output"
root_status=$?
"$child_output"
child_status=$?
set -e
[[ $root_status -eq 0 ]]
[[ $child_status -eq 8 ]]
grep -Fq 'compiler.addFunctionAnnotation' "$generated_entry"
grep -Fq 'fun main: int = lifted() + annotatedLift()' "$generated_entry"

set +e
"$compiler" build \
    "$project_root/tests/cases/program-build/invalid-independent-module-reference.ab" \
    -o "$output_directory/invalid-reference" --fast --no-cache \
    >"$output_directory/invalid-reference.out" \
    2>"$output_directory/invalid-reference.err"
invalid_reference_status=$?
"$compiler" build \
    "$project_root/tests/cases/program-build/invalid-runtime-declaration-block.ab" \
    -o "$output_directory/invalid-runtime-block" --fast --no-cache \
    >"$output_directory/invalid-runtime-block.out" \
    2>"$output_directory/invalid-runtime-block.err"
invalid_runtime_status=$?
set -e

[[ $invalid_reference_status -ne 0 ]]
[[ $invalid_runtime_status -ne 0 ]]
grep -Fq 'error[E_INDEPENDENT_MODULE_USE]' \
    "$output_directory/invalid-reference.err"
grep -Fq 'declaration.block.compile-only' \
    "$output_directory/invalid-runtime-block.err"

printf '%s\n' \
    'independent modules: typed references, declaration blocks, annotations, standalone child, and diagnostics passed'
