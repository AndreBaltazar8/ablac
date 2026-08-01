#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/return-control"
mkdir -p "$output_directory"

program="$output_directory/program"
"$compiler" build \
    "$project_root/tests/cases/modules/return-control.ab" \
    -o "$program"

set +e
"$project_root/tools/run-limited.sh" "$program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "return-control: expected 42, got $status" >&2
    exit 1
fi

rm -f "$output_directory/invalid"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-return-type.ab" \
    -o "$output_directory/invalid" \
    >"$output_directory/invalid-output.txt" \
    2>"$output_directory/invalid-errors.txt"
invalid_status=$?
set -e

if [[ $invalid_status -ne 1 ]]; then
    echo "return-control: invalid return type was accepted" >&2
    exit 1
fi
if ! grep -Fq 'return.type' "$output_directory/invalid-errors.txt"; then
    echo "return-control: missing return.type diagnostic" >&2
    sed -n '1,80p' "$output_directory/invalid-errors.txt" >&2
    exit 1
fi
if [[ -e "$output_directory/invalid" ]]; then
    echo "return-control: invalid program produced an executable" >&2
    exit 1
fi

"$compiler" build \
    "$project_root/tests/cases/modules/return-c-backend.ab" \
    -o "$output_directory/c-generator"
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
    echo "return-control: C backend expected 42, got $c_status" >&2
    exit 1
fi

echo "return-control: LLVM/C runtime, compile-time, lambda, method, void, and diagnostic checks passed"
