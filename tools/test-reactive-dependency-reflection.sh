#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/reactive-dependency-reflection"
source_file="$project_root/tests/cases/modules/reactive-dependency-reflection.ab"
mkdir -p "$output_directory"
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
export ABLA_MAX_SECONDS=${ABLA_MAX_SECONDS:-300}
export ABLA_MAX_CPU_SECONDS=${ABLA_MAX_CPU_SECONDS:-$ABLA_MAX_SECONDS}

"$compiler" build "$source_file" -o "$output_directory/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'reactive dependency reflection: expected 42, got %s\n' \
        "$status" >&2
    exit 1
fi

"$compiler" --emit-llvm "$source_file" > "$output_directory/first.ll"
"$compiler" --emit-llvm "$source_file" > "$output_directory/second.ll"
cmp "$output_directory/first.ll" "$output_directory/second.ll"
opt --threads=1 -passes=verify -disable-output "$output_directory/first.ll"

fixtures=(
    invalid-reactive-early-query
    invalid-reactive-lift-free-variable
    invalid-reactive-lift-ownership
    invalid-reactive-lift-immutable-capture
)
diagnostics=(
    E_REACTIVE_DEPENDENCY_UNAVAILABLE
    E_REACTIVE_LIFT_FREE_VARIABLE
    E_REACTIVE_LIFT_OWNERSHIP
    E_REACTIVE_HANDLER_CAPTURE
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
        printf 'reactive dependency reflection: %s did not report %s\n' \
            "$fixture" "$expected" >&2
        sed -n '1,100p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]]
    index=$((index + 1))
done

printf '%s\n' \
    'reactive dependency reflection: direct/transitive paths, aliases, indexes, cells, lifting, diagnostics, and determinism passed'
