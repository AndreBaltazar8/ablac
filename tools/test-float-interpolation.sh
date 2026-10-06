#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_directory=$project_root/build/tests/float-interpolation
cases=$project_root/tests/cases/modules

mkdir -p "$output_directory"
for mode in "" --fast; do
    "$compiler" build "$cases/float-interpolation.ab" \
        -o "$output_directory/program" --no-cache $mode
    set +e
    "$output_directory/program"
    status=$?
    set -e
    if [[ $status -ne 42 ]]; then
        printf 'float interpolation %s: exited %d, expected 42\n' \
            "${mode:-default}" "$status" >&2
        exit 1
    fi
done

set +e
"$compiler" build "$cases/invalid-float-interpolation-import.ab" \
    -o "$output_directory/invalid" --no-cache --fast \
    > "$output_directory/invalid.out" 2>&1
invalid_status=$?
set -e
[[ $invalid_status -ne 0 ]] || exit 1
grep -q 'import "abla/float/text" to interpolate a float' \
    "$output_directory/invalid.out"

printf '%s\n' 'f64 and f32 interpolate as JavaScript writes them'
