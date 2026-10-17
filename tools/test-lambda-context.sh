#!/usr/bin/env bash
# A lambda without parameter types takes them from where it is stored: an
# array's or a map's element type (append, set, an index, a literal), a field,
# a variable, at run time and under `#`.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/lambda-context"
output_directory="$project_root/build/lambda-context"
mkdir -p "$output_directory"

"$compiler" build "$cases/main.ab" -o "$output_directory/main" --no-cache
set +e
output=$("$output_directory/main")
status=$?
set -e
expected='a3
116 [x] 1001 3 3'
[[ $status -eq 42 && $output == "$expected" ]] || {
    echo "lambda context: status $status, output:"; echo "$output"; exit 1
}
echo "lambda context: parameter types from element, field and variable types"
