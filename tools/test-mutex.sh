#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/mutex"
source_file="$project_root/tests/cases/modules/mutex.ab"
mkdir -p "$output_directory"

"$compiler" --emit-llvm "$source_file" > "$output_directory/program.ll"
opt --threads=1 -passes=verify -disable-output "$output_directory/program.ll"
"$compiler" build "$source_file" -o "$output_directory/program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "mutex: LLVM expected 42, got $status" >&2
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
    echo "mutex: generated C expected 42, got $c_status" >&2
    exit 1
fi

fixtures=(invalid-mutex-callback-mode invalid-mutex-element)
diagnostics=('mutex.with.callback-mode' 'mutex.element-affine:Counter')
index=0
while [[ $index -lt ${#fixtures[@]} ]]; do
    output="$output_directory/${fixtures[$index]}"
    rm -f "$output"
    set +e
    "$compiler" build \
        "$project_root/tests/cases/bootstrap/${fixtures[$index]}.ab" \
        -o "$output" >"$output.out" 2>"$output.err"
    fixture_status=$?
    set -e
    if [[ $fixture_status -ne 1 ]] ||
        ! grep -Fq "${diagnostics[$index]}" "$output.err"; then
        echo "mutex: ${fixtures[$index]} diagnostic mismatch" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]]
    index=$((index + 1))
done

echo 'mutex: synchronized clone/with + staging + LLVM/C passed'
