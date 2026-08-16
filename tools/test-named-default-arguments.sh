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
    [[ $status -ne 0 ]]
    grep -q "error\[E_NAMED_ARGUMENT_${diagnostic}\]" \
        "$output_directory/$stem.err"
}

check_failure invalid-named-argument-unknown.ab UNKNOWN
check_failure invalid-named-argument-duplicate.ab DUPLICATE
check_failure invalid-named-argument-order.ab ORDER

echo "named/default arguments: invalid name, duplicate, and order diagnostics passed"
