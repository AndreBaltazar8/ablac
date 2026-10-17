#!/usr/bin/env bash
# `return` of the wrong type names both types (as function.result does), and
# returning a closure that changes its captures as `() -> T` hints at FnMut.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/return-type-diagnostic"
mkdir -p "$output_directory"

expect() { # file text…
    local file=$1; shift
    set +e
    diagnostics=$("$compiler" build "$project_root/tests/cases/modules/$file.ab" \
        -o "$output_directory/$file" --no-cache 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 ]] || { echo "$file: built"; exit 1; }
    for text in "$@"; do
        [[ $diagnostics == *"$text"* ]] || { echo "$file: missing '$text'"; echo "$diagnostics"; exit 1; }
    done
}

expect invalid-return-type "return.type@" ":i64:string" "invalid-return-type.ab:19:20"
expect invalid-return-fnmut "return.type@" "help: the returned closure changes what it captured" "FnMut(...) -> T"
echo "return.type: names expected and found types; FnMut hint for a mutating closure"
