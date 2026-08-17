#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/loop-control"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/loop-control.ab" \
    -o "$output_directory/program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "loop-control: expected 42, got $status" >&2
    exit 1
fi

rm -f "$output_directory/invalid"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-loop-control.ab" \
    -o "$output_directory/invalid" \
    >"$output_directory/invalid-output.txt" \
    2>"$output_directory/invalid-errors.txt"
invalid_status=$?
set -e
if [[ $invalid_status -ne 1 ]]; then
    echo "loop-control: out-of-loop control was accepted" >&2
    exit 1
fi
grep -Fq 'break.outside-loop' "$output_directory/invalid-errors.txt"
grep -Fq 'continue.outside-loop' "$output_directory/invalid-errors.txt"
if [[ -e "$output_directory/invalid" ]]; then
    echo "loop-control: invalid program produced an executable" >&2
    exit 1
fi

rm -f "$output_directory/invalid-lambda"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-lambda-loop-control.ab" \
    -o "$output_directory/invalid-lambda" \
    >"$output_directory/invalid-lambda-output.txt" \
    2>"$output_directory/invalid-lambda-errors.txt"
lambda_status=$?
set -e
if [[ $lambda_status -ne 1 ]] ||
    ! grep -Fq 'break.outside-loop' \
        "$output_directory/invalid-lambda-errors.txt"; then
    echo "loop-control: lambda illegally inherited caller loop context" >&2
    exit 1
fi
if [[ -e "$output_directory/invalid-lambda" ]]; then
    echo "loop-control: invalid lambda produced an executable" >&2
    exit 1
fi

echo "loop-control: nested/runtime/compile-time/do-while/LLVM/diagnostic checks passed"
