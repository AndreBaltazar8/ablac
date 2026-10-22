#!/usr/bin/env bash
# Delegated class properties (`var balance: int by Box(0)`): the semantics
# program natively, and each misuse with its diagnostic.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/delegated-properties"
mkdir -p "$output_directory"
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
export ABLA_MAX_SECONDS=${ABLA_MAX_SECONDS:-300}
export ABLA_MAX_CPU_SECONDS=${ABLA_MAX_CPU_SECONDS:-$ABLA_MAX_SECONDS}

for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build \
        "$project_root/tests/cases/modules/delegated-properties.ab" \
        -o "$output_directory/program-$mode" --no-cache
    set +e
    "$project_root/tools/run-limited.sh" "$output_directory/program-$mode"
    status=$?
    set -e
    if [[ $status -ne 42 ]]; then
        printf 'delegated properties (%s): expected 42, got %s\n' "$mode" "$status" >&2
        exit 1
    fi
done

fixtures=(
    invalid-delegated-property-getter
    invalid-delegated-property-setter
    invalid-delegated-property-assign-val
    invalid-delegated-property-replace-val
    invalid-delegated-property-replace-type
    invalid-delegated-property-projection
    invalid-delegated-property-argument
    invalid-delegated-property-parameter
    invalid-delegated-property-later
    invalid-delegated-property-self
    invalid-delegated-property-this
    invalid-delegated-extension-field
)
diagnostics=(
    E_DELEGATE_GETTER_MISSING
    E_DELEGATE_SETTER_MISSING
    member.immutable:Holder.value
    E_DELEGATE_REPLACE_VAL
    E_DELEGATE_TYPE_MISMATCH
    E_NOT_DELEGATED
    E_NAMED_ARGUMENT_DELEGATED
    E_PARSE_DELEGATED_PARAMETER
    E_DELEGATE_INITIALIZER_SCOPE
    E_DELEGATE_INITIALIZER_SCOPE
    E_DELEGATE_INITIALIZER_SCOPE
    field.extension-delegate:Point.label
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
    # One diagnosis each: the plain code it becomes reports nothing more.
    errors=$(grep -c '^error\[' "$output.err" || true)
    if [[ $result -ne 1 ]] || ! grep -Fq "$expected" "$output.err" || [[ $errors -ne 1 ]]; then
        printf 'delegated properties: %s did not report %s alone\n' \
            "$fixture" "$expected" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]] || exit 1
    index=$((index + 1))
done

printf '%s\n' \
    'delegated properties: reads, assignments, projection, replacement, construction, resources, compile time and diagnostics passed'
