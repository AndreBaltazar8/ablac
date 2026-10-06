#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_directory=$project_root/build/tests/closure-captures
source_file=$project_root/tests/cases/modules/closure-captures.ab
program=$output_directory/program

mkdir -p "$output_directory"
for mode in "" --fast; do
    "$compiler" build "$source_file" -o "$program" --no-cache $mode
    set +e
    "$program"
    status=$?
    set -e
    if [[ $status -ne 42 ]]; then
        printf 'closure captures %s: exited %d, expected 42\n' \
            "${mode:-default}" "$status" >&2
        exit 1
    fi
done

printf '%s\n' 'closures capture locals in loops and branches; boxed f64 results stay f64'
