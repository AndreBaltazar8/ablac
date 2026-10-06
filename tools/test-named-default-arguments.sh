#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/named-default-arguments"
mkdir -p "$output_directory"

check_failure() {
    local source=$1
    local diagnostic=$2
    local stem=${source%.ab}
    set +e
    "$compiler" build \
        "$project_root/tests/cases/modules/$source" \
        -o "$output_directory/$stem" --fast --no-cache \
        >"$output_directory/$stem.out" \
        2>"$output_directory/$stem.err"
    local status=$?
    set -e
    [[ $status -ne 0 ]] || exit 1
    grep -q "error\[E_NAMED_ARGUMENT_${diagnostic}\]" \
        "$output_directory/$stem.err"
}

check_failure invalid-named-argument-unknown.ab UNKNOWN
check_failure invalid-named-argument-duplicate.ab DUPLICATE
check_failure invalid-named-argument-order.ab ORDER

"$compiler" build \
    "$project_root/tests/cases/modules/named-many-default-arguments.ab" \
    -o "$output_directory/named-many-default-arguments" --fast --no-cache
set +e
"$output_directory/named-many-default-arguments"
named_many_status=$?
set -e
[[ $named_many_status -eq 42 ]] || exit 1

"$compiler" build \
    "$project_root/tests/cases/modules/named-var-arguments.ab" \
    -o "$output_directory/named-var-arguments" --fast --no-cache
set +e
"$output_directory/named-var-arguments"
named_var_status=$?
set -e
[[ $named_var_status -eq 42 ]] || exit 1

echo "named/default arguments: extension defaults, var parameters and invalid diagnostics passed"
