#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
c_compiler=${ABLA_C_DIFFERENTIAL_COMPILER:-$project_root/build/bootstrap/ablac-llvm}
output_directory="$project_root/build/scoped-region"
mkdir -p "$output_directory"

source_file="$project_root/tests/cases/modules/scoped-region.ab"
"$compiler" --emit-llvm "$source_file" > "$output_directory/program.ll"
if ! grep -Eq '@(abla_runtime_memory_checkpoint|ablaRuntimeMemoryCheckpoint|ablaRuntimeRegionBegin)' \
        "$output_directory/program.ll" ||
    ! grep -Eq '@(abla_runtime_memory_reset|ablaRuntimeMemoryReset|ablaRuntimeRegionEnd)' \
        "$output_directory/program.ll"; then
    echo 'scoped region: LLVM cleanup intrinsics were not emitted' >&2
    exit 1
fi

"$compiler" build "$source_file" -o "$output_directory/program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
native_status=$?
set -e
if [[ $native_status -ne 42 ]]; then
    echo "scoped region: LLVM expected 42, got $native_status" >&2
    exit 1
fi

"$c_compiler" "$source_file" > "$output_directory/program.c"
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
    echo "scoped region: generated C expected 42, got $c_status" >&2
    exit 1
fi

fixtures=(
    invalid-region-break
    invalid-region-heap-global
    invalid-region-indirect-call
    invalid-region-noescape-effect
    invalid-region-noescape-method-effect
    invalid-region-outer-append
    invalid-region-outer-assignment
    invalid-region-outer-field
    invalid-region-outer-index
    invalid-region-outer-method
    invalid-region-result
    invalid-region-retaining-call
    invalid-region-return
    invalid-region-transitive-call
    invalid-region-transitive-receiver
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
    if [[ $status -ne 1 ]] || ! grep -Fq 'region.' "$output.err"; then
        echo "scoped region: $fixture was not rejected" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]]
done

noescape_callback_output="$output_directory/invalid-noescape-callback-type"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-region-noescape-callback-type.ab" \
    -o "$noescape_callback_output" \
    >"$noescape_callback_output.out" \
    2>"$noescape_callback_output.err"
noescape_callback_status=$?
set -e
if [[ $noescape_callback_status -ne 1 ]] ||
    ! grep -Fq 'function.argument:requireNoEscape' \
        "$noescape_callback_output.err"; then
    echo 'scoped region: ordinary callback satisfied FnNoEscape' >&2
    sed -n '1,80p' "$noescape_callback_output.err" >&2
    exit 1
fi
[[ ! -e $noescape_callback_output ]]

echo 'scoped region: nested LIFO reset + affine drops + compile time + LLVM/C + retention effects passed'
