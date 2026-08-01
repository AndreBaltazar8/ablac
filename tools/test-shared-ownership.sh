#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/shared-ownership"
mkdir -p "$output_directory"

"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/shared-ownership.ab" \
    > "$output_directory/with-shared.ll"
if ! grep -Fq '@abla_shared_create' "$output_directory/with-shared.ll" ||
    ! grep -Fq '@abla_weak_upgrade' "$output_directory/with-shared.ll"; then
    echo "shared ownership: LLVM runtime was not selected" >&2
    exit 1
fi

"$compiler" --emit-llvm \
    "$project_root/tests/cases/bootstrap/block.ab" \
    > "$output_directory/without-shared.ll"
if grep -Fq '@abla_shared_create' "$output_directory/without-shared.ll" ||
    grep -Fq '%AblaShared = type' "$output_directory/without-shared.ll"; then
    echo "shared ownership: unused LLVM runtime was emitted" >&2
    exit 1
fi

"$compiler" build \
    "$project_root/tests/cases/modules/shared-ownership.ab" \
    -o "$output_directory/program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
native_status=$?
set -e
if [[ $native_status -ne 42 ]]; then
    echo "shared ownership: LLVM expected 42, got $native_status" >&2
    exit 1
fi

"$compiler" "$project_root/tests/cases/modules/shared-ownership.ab" \
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
    echo "shared ownership: generated C expected 42, got $c_status" >&2
    exit 1
fi

fixtures=(
    invalid-shared-handle-copy
    invalid-shared-borrow-store
    invalid-shared-borrow-return
    invalid-shared-borrow-reshare
    invalid-shared-borrow-mutation
    invalid-shared-non-affine
    invalid-weak-handle-copy
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
    if [[ $status -ne 1 ]] || {
        ! grep -Fq 'ownership.' "$output.err" &&
        ! grep -Fq 'shared.' "$output.err"
    }; then
        echo "shared ownership: $fixture was not rejected" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]]
done

echo "shared ownership: selective LLVM runtime + explicit clone + one final payload drop + checked borrow storage passed"
