#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/concurrency"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/concurrency.ab" \
    --no-cache -o "$output_directory/program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "concurrency: LLVM program expected 42, got $status" >&2
    exit 1
fi

rm -f "$output_directory/invalid"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-concurrency.ab" \
    --no-cache -o "$output_directory/invalid" \
    >"$output_directory/invalid.out" \
    2>"$output_directory/invalid.err"
invalid_status=$?
set -e
if [[ $invalid_status -ne 1 ]]; then
    echo "concurrency: invalid program was accepted" >&2
    exit 1
fi
diagnostics=(
    'yield.outside-generator'
    'await.type:i64'
    'generator.empty'
    'yield.affine:shared:Ticket'
    'task.affine-result:Ticket'
    'thread.capture-type:value:i64'
    'thread.capture-mutation'
    'thread.mutable-global'
)
for diagnostic in "${diagnostics[@]}"; do
    grep -Fq "$diagnostic" "$output_directory/invalid.err"
done
[[ ! -e $output_directory/invalid ]]

defer_fixtures=(invalid-defer-result invalid-defer-control)
defer_diagnostics=(defer.result defer.control)
for index in "${!defer_fixtures[@]}"; do
    fixture=${defer_fixtures[$index]}
    rm -f "$output_directory/$fixture"
    set +e
    "$compiler" build \
        "$project_root/tests/cases/bootstrap/$fixture.ab" \
        --no-cache -o "$output_directory/$fixture" \
        >"$output_directory/$fixture.out" \
        2>"$output_directory/$fixture.err"
    fixture_status=$?
    set -e
    if [[ $fixture_status -ne 1 ]]; then
        echo "concurrency: $fixture was accepted" >&2
        exit 1
    fi
    grep -Fq "${defer_diagnostics[$index]}" \
        "$output_directory/$fixture.err"
    [[ ! -e $output_directory/$fixture ]]
done

"$compiler" build \
    "$project_root/tests/cases/modules/concurrency-c-backend.ab" \
    --fast --no-cache -o "$output_directory/c-generator"
"$project_root/tools/run-limited.sh" \
    "$output_directory/c-generator" >"$output_directory/program.c"
clang -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror -pthread \
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
    echo "concurrency: C program expected 42, got $c_status" >&2
    exit 1
fi

echo 'concurrency: defer/generator/task/thread LLVM/C/diagnostic checks passed'
