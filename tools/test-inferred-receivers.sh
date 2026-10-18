#!/usr/bin/env bash
# An array literal stored into a receiver whose type is only inferred (an
# inferred local's append, `[i] =`, `=`, Map set, field, method argument)
# takes the receiver's type, at runtime and under `#`; its elements are still
# checked against it.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/inferred-receivers"
output_directory="$project_root/build/inferred-receivers"
mkdir -p "$output_directory"

"$compiler" build "$cases/main.ab" -o "$output_directory/main" --no-cache
set +e
output=$("$output_directory/main")
status=$?
"$compiler" build "$cases/invalid-element.ab" -o "$output_directory/invalid" \
    --no-cache > "$output_directory/invalid.err" 2>&1
invalid_status=$?
set -e
expected='2 4 true 2 true 1 2 true|2 4 true 2 true 1 2 true'
[[ $status -eq 0 && $output == "$expected" ]] || {
    echo "inferred receivers: status $status, output:"; echo "$output"; exit 1
}
[[ $invalid_status -ne 0 ]] || { echo "inferred receivers: [null, 4] into array<string?> built"; exit 1; }
grep -q 'array.element-type' "$output_directory/invalid.err"
grep -q 'invalid-element.ab:8:24' "$output_directory/invalid.err"
[[ $(grep -c '^error' "$output_directory/invalid.err") -eq 1 ]]
echo "inferred receivers: literals take the inferred receiver's type, at runtime and under #"
