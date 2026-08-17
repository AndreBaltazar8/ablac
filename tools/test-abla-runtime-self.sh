#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_directory="$project_root/build/abla-runtime-self"
mkdir -p -- "$output_directory"

fixtures=(runtime-self-intrinsics runtime-path-parent)
for fixture in "${fixtures[@]}"; do
    output="$output_directory/$fixture"
    "$compiler" build "$project_root/tests/cases/$fixture.ab" \
        -o "$output" --fast --no-cache
    set +e
    "$project_root/tools/run-limited.sh" "$output"
    status=$?
    set -e
    if [[ $status -ne 42 ]]; then
        printf 'Abla runtime: %s expected 42, got %s\n' \
            "$fixture" "$status" >&2
        exit 1
    fi
done

printf '%s\n' 'Abla runtime: value intrinsics, empty strings, paths, and atomic writes passed'
