#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/definite-assignment"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/definite-assignment.ab" \
    -o "$output_directory/program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "definite-assignment: expected 42, got $status" >&2
    exit 1
fi

check_rejected() {
    local fixture=$1
    local diagnostic=$2
    local output="$output_directory/$fixture"
    rm -f "$output"
    set +e
    "$compiler" build \
        "$project_root/tests/cases/bootstrap/$fixture.ab" \
        -o "$output" >"$output.out" 2>"$output.err"
    local result=$?
    set -e
    if [[ $result -ne 1 ]] || ! grep -Fq "$diagnostic" "$output.err"; then
        echo "definite-assignment: $fixture was not rejected with $diagnostic" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    if [[ -e $output ]]; then
        echo "definite-assignment: $fixture produced an executable" >&2
        exit 1
    fi
}

check_rejected invalid-definite-assignment ir.verification
check_rejected invalid-uninitialized-val local.uninitialized-val
check_rejected invalid-uninitialized-type local.uninitialized-type

"$compiler" build \
    "$project_root/tests/cases/modules/definite-assignment-c-backend.ab" \
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
    echo "definite-assignment: C backend expected 42, got $c_status" >&2
    exit 1
fi

echo "definite-assignment: CFG paths + compile-time + LLVM/C checks passed"
