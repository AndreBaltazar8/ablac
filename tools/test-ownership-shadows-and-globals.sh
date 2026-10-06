#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_directory=$project_root/build/tests/ownership-shadows-and-globals
cases=$project_root/tests/cases/modules

mkdir -p "$output_directory"
"$compiler" build "$cases/ownership-shadows-and-globals.ab" \
    -o "$output_directory/program" --no-cache --fast
set +e
"$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'ownership shadows and globals: exited %d, expected 42\n' \
        "$status" >&2
    exit 1
fi

set +e
"$compiler" build "$cases/invalid-receiver-shadowed-late.ab" \
    -o "$output_directory/invalid" --no-cache --fast \
    > "$output_directory/invalid.out" 2>&1
invalid_status=$?
set -e
[[ $invalid_status -ne 0 ]]
grep -q 'ownership.mutable-borrow:receiver.Obj.sneaky' \
    "$output_directory/invalid.out"

printf '%s\n' 'shadowing locals leave the receiver alone; global-rooted references return'
