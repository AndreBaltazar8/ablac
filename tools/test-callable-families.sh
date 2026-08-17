#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/callable-families"
source_file="$project_root/tests/cases/modules/callable-families.ab"
mkdir -p "$output_directory"

"$compiler" --emit-llvm "$source_file" > "$output_directory/program.ll"
opt --threads=1 -passes=verify -disable-output "$output_directory/program.ll"
"$compiler" build "$source_file" -o "$output_directory/program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "callable families: expected 42, got $status" >&2
    exit 1
fi

fixtures=(
    invalid-fnmut-parameter-mode
    invalid-fnonce-parameter-mode
    invalid-fnmut-copy
)
diagnostics=(
    'ownership.fnmut-parameter-mode:invoke'
    'ownership.fnonce-parameter-mode:invoke'
    'ownership.move-required:local.copied:callback'
)

index=0
while [[ $index -lt ${#fixtures[@]} ]]; do
    fixture=${fixtures[$index]}
    output="$output_directory/$fixture"
    rm -f "$output"
    set +e
    "$compiler" build \
        "$project_root/tests/cases/bootstrap/$fixture.ab" \
        -o "$output" >"$output.out" 2>"$output.err"
    fixture_status=$?
    set -e
    if [[ $fixture_status -ne 1 ]] ||
        ! grep -Fq "${diagnostics[$index]}" "$output.err"; then
        echo "callable families: ${fixtures[$index]} diagnostic mismatch" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]]
    index=$((index + 1))
done

echo 'callable families: Fn/FnMut/FnOnce inference, capture, staging, and LLVM passed'
