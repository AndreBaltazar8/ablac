#!/usr/bin/env bash
# A lambda's function is named after its span and its owner's lowered name:
# lambdas at the same spans in two files (in functions, globals' initializers
# and methods), and the lambda of each instance of a generic function and of
# a generic class's method, each get a symbol of their own. They shared one,
# and the build failed in LLVM emission.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/lambda-symbols"
output_directory="$project_root/build/lambda-symbols"
mkdir -p "$output_directory"

"$compiler" build "$cases/main.ab" -o "$output_directory/main" --no-cache
set +e
output=$("$output_directory/main")
status=$?
set -e
expected='6 35 7 25 7 12
9 12 3 6'
[[ $status -eq 42 && $output == "$expected" ]] || {
    echo "lambda symbols: status $status, output:"; echo "$output"; exit 1
}
echo "lambda symbols: the same spans in two files and in a generic's instances"
