#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/for-range"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/for-range.ab" \
    -o "$output_directory/program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "for-range: expected 42, got $status" >&2
    exit 1
fi

rm -f "$output_directory/invalid"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-for-range.ab" \
    -o "$output_directory/invalid" \
    >"$output_directory/invalid-output.txt" \
    2>"$output_directory/invalid-errors.txt"
invalid_status=$?
set -e
if [[ $invalid_status -ne 1 ]]; then
    echo "for-range: invalid program was accepted" >&2
    exit 1
fi
grep -Fq 'for.source' "$output_directory/invalid-errors.txt"
grep -Fq 'range.bound-type' "$output_directory/invalid-errors.txt"
if [[ -e "$output_directory/invalid" ]]; then
    echo "for-range: invalid program produced an executable" >&2
    exit 1
fi

rm -f "$output_directory/invalid-mutation"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-for-mutation.ab" \
    -o "$output_directory/invalid-mutation" \
    >"$output_directory/invalid-mutation-output.txt" \
    2>"$output_directory/invalid-mutation-errors.txt"
mutation_status=$?
set -e
if [[ $mutation_status -ne 1 ]] ||
    ! grep -Fq 'assignment.immutable:value' \
        "$output_directory/invalid-mutation-errors.txt"; then
    echo "for-range: iterator mutation was not rejected" >&2
    exit 1
fi
if [[ -e "$output_directory/invalid-mutation" ]]; then
    echo "for-range: invalid iterator mutation produced an executable" >&2
    exit 1
fi

rm -f "$output_directory/invalid-scope"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-for-scope.ab" \
    -o "$output_directory/invalid-scope" \
    >"$output_directory/invalid-scope-output.txt" \
    2>"$output_directory/invalid-scope-errors.txt"
scope_status=$?
set -e
if [[ $scope_status -ne 1 ]] ||
    ! grep -Fq 'identifier:value' \
        "$output_directory/invalid-scope-errors.txt"; then
    echo "for-range: iterator escaped its lexical scope" >&2
    exit 1
fi
if [[ -e "$output_directory/invalid-scope" ]]; then
    echo "for-range: invalid iterator escape produced an executable" >&2
    exit 1
fi

"$compiler" build \
    "$project_root/tests/cases/modules/for-range-c-backend.ab" \
    -o "$output_directory/c-generator" --no-cache
"$project_root/tools/run-limited.sh" \
    "$output_directory/c-generator" >"$output_directory/program.c"
clang -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
    -I"$project_root/runtime" \
    "$output_directory/program.c" \
    "$project_root/runtime/abla_runtime.c" \
    "$project_root/runtime/abla_runtime_host.c" \
    -o "$output_directory/c-program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/c-program"
c_status=$?
set -e
if [[ $c_status -ne 42 ]]; then
    echo "for-range: C backend expected 42, got $c_status" >&2
    exit 1
fi

echo "for-range: inclusive/exclusive/array/string/capture/compile-time/LLVM/C checks passed"
