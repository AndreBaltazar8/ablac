#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/nullable-refinement"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/nullable-refinement.ab" \
    -o "$output_directory/program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
native_status=$?
set -e
if [[ $native_status -ne 42 ]]; then
    echo "nullable refinement: LLVM expected 42, got $native_status" >&2
    exit 1
fi

fixtures=(
    invalid-nullable-mutable-refinement
    invalid-nullable-field-refinement
    invalid-nullable-refinement-escape
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
    if [[ $status -ne 1 ]] ||
        ! grep -Fq 'member:nullable:' "$output.err"; then
        echo "nullable refinement: $fixture was not rejected" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]]
done

echo "nullable refinement: stable locals/parameters + branch polarity + compile-time/LLVM passed"
