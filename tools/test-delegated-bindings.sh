#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/delegated-bindings"
mkdir -p "$output_directory"
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
export ABLA_MAX_SECONDS=${ABLA_MAX_SECONDS:-300}
export ABLA_MAX_CPU_SECONDS=${ABLA_MAX_CPU_SECONDS:-$ABLA_MAX_SECONDS}

"$compiler" build \
    "$project_root/tests/cases/modules/delegated-bindings.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'delegated bindings: LLVM expected 42, got %s\n' "$status" >&2
    exit 1
fi

fixtures=(
    invalid-delegate-getter
    invalid-delegate-getter-result
    invalid-delegate-getter-arity
    invalid-delegate-setter
    invalid-delegate-setter-result
    invalid-delegate-setter-input
    invalid-delegate-projection
    invalid-delegate-replace-val
    invalid-delegate-replace-type
    invalid-delegate-move
    invalid-delegate-affine-value
    invalid-delegate-alias-replacement
    invalid-delegate-compile-effect
)
diagnostics=(
    E_DELEGATE_GETTER_MISSING
    E_DELEGATE_GETTER_MISSING
    E_DELEGATE_GETTER_MISSING
    E_DELEGATE_SETTER_MISSING
    E_DELEGATE_SETTER_MISSING
    E_DELEGATE_SETTER_MISSING
    E_NOT_DELEGATED
    E_DELEGATE_REPLACE_VAL
    E_DELEGATE_TYPE_MISMATCH
    E_DELEGATE_MOVE_PROJECTION
    E_DELEGATE_AFFINE_VALUE
    E_DELEGATE_BORROW_CONFLICT
    compile.effect-denied:environment
)

index=0
while [[ $index -lt ${#fixtures[@]} ]]; do
    fixture=${fixtures[$index]}
    expected=${diagnostics[$index]}
    output="$output_directory/$fixture"
    rm -f -- "$output"
    set +e
    "$compiler" build \
        "$project_root/tests/cases/modules/$fixture.ab" \
        -o "$output" --no-cache >"$output.out" 2>"$output.err"
    result=$?
    set -e
    if [[ $result -ne 1 ]] || ! grep -Fq "$expected" "$output.err"; then
        printf 'delegated bindings: %s did not report %s\n' \
            "$fixture" "$expected" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]]
    index=$((index + 1))
done

"$compiler" build \
    "$project_root/tests/cases/modules/delegated-bindings-c-backend.ab" \
    -o "$output_directory/c-generator" --no-cache
"$project_root/tools/run-limited.sh" "$output_directory/c-generator" \
    > "$output_directory/program.c"
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
    printf 'delegated bindings: generated C expected 42, got %s\n' \
        "$c_status" >&2
    exit 1
fi

printf '%s\n' \
    'delegated bindings: contracts, projection, replacement, ownership, staging, LLVM, and C passed'
