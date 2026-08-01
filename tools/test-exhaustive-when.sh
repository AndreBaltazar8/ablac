#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/exhaustive-when"
mkdir -p "$output_directory"

source_file="$project_root/tests/cases/modules/exhaustive-when.ab"
"$compiler" --emit-llvm "$source_file" > "$output_directory/program.ll"
opt --threads=1 -passes=verify -disable-output "$output_directory/program.ll"

"$compiler" build "$source_file" -o "$output_directory/program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
native_status=$?
set -e
if [[ $native_status -ne 42 ]]; then
    echo "exhaustive when: LLVM expected 42, got $native_status" >&2
    exit 1
fi

"$compiler" "$source_file" > "$output_directory/program.c"
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
    echo "exhaustive when: generated C expected 42, got $c_status" >&2
    exit 1
fi

fixtures=(
    invalid-when-non-exhaustive
    invalid-when-bool-non-exhaustive
    invalid-when-else-order
    invalid-when-else-duplicate
    invalid-when-duplicate
    invalid-when-empty
    invalid-never-result
    invalid-never-breaking-loop
)
diagnostics=(
    'when.non-exhaustive:i64'
    'when.non-exhaustive:bool'
    'when.else-last'
    'when.else-duplicate'
    'when.duplicate:integer:1'
    'when.empty'
    'function.result:returnsAfterAll'
    'function.result:canReturn'
)

index=0
while [[ $index -lt ${#fixtures[@]} ]]; do
    fixture=${fixtures[$index]}
    expected=${diagnostics[$index]}
    output="$output_directory/$fixture"
    rm -f "$output"
    set +e
    "$compiler" build \
        "$project_root/tests/cases/bootstrap/$fixture.ab" \
        -o "$output" >"$output.out" 2>"$output.err"
    status=$?
    set -e
    if [[ $status -ne 1 ]] || ! grep -Fq "$expected" "$output.err"; then
        echo "exhaustive when: $fixture was not rejected with $expected" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]]
    index=$((index + 1))
done

echo 'exhaustive when/never: bool coverage + else rules + compile-time/LLVM/C + verified unreachable passed'
