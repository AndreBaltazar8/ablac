#!/usr/bin/env bash
# `$json` literals: a repeated literal key and a trailing comma are errors at the
# literal, and a value it can't convert says what it accepts.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/json-literal-diagnostics"
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

expect json-duplicate-key 'duplicate key "a"'
expect json-trailing-comma "trailing comma in a \$json object"
expect json-trailing-comma-array "trailing comma in a \$json array"
expect json-unconvertible "can't convert a value of type P"
echo "json literal diagnostics: duplicate keys, trailing commas, unconvertible values"
