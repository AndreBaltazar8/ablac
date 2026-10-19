#!/usr/bin/env bash
# `$json` literals: a repeated literal key and a comma with nothing before it are
# errors at the literal (a trailing comma is allowed, tools/test-json-expressions.sh),
# and a value it can't convert says what it accepts.
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
expect json-stray-comma "expected a \$json object member before \`,\`"
expect json-stray-comma-array "expected a \$json array element before \`,\`"
expect json-unconvertible "can't convert a value of type P"
echo "json literal diagnostics: duplicate keys, stray commas, unconvertible values"
