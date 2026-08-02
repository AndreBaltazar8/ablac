#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
c_compiler=${ABLA_C_DIFFERENTIAL_COMPILER:-$project_root/build/bootstrap/ablac-llvm}
output_directory="$project_root/build/nullable-refinement"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/nullable-refinement.ab" \
    -o "$output_directory/program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
native_status=$?
set -e
if [[ $native_status -ne 42 ]]; then
    echo "nullable refinement: LLVM expected 42, got $native_status" >&2
    exit 1
fi

"$c_compiler" "$project_root/tests/cases/modules/nullable-refinement.ab" \
    > "$output_directory/program.c"
clang -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
    -I"$project_root/runtime" \
    "$output_directory/program.c" \
    "$project_root/runtime/abla_runtime.c" \
    "$project_root/runtime/abla_runtime_host.c" \
    -o "$output_directory/program-c"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program-c"
c_status=$?
set -e
if [[ $c_status -ne 42 ]]; then
    echo "nullable refinement: generated C expected 42, got $c_status" >&2
    exit 1
fi

fixtures=(
    invalid-nullable-mutable-refinement
    invalid-nullable-field-refinement
    invalid-nullable-refinement-escape
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
    if [[ $status -ne 1 ]] ||
        ! grep -Fq 'member:nullable:' "$output.err"; then
        echo "nullable refinement: $fixture was not rejected" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]]
done

echo "nullable refinement: stable locals/parameters + branch polarity + compile-time/LLVM/C passed"
