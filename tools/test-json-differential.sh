#!/usr/bin/env bash
# JSON results under mutation (tests/cases/json-differential): every input's
# parse, object-reader and array-reader outcome (codes, positions, messages,
# trees, raw slices) under six sets of limits must hash, block by block, to what
# the plain parser and readers produced when the expected output was recorded.
# On a mismatch, run the program with the argument "full" for every input's line.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/json-differential"
output_directory="$project_root/build/json-differential"
mkdir -p "$output_directory"
"$compiler" build "$cases/main.ab" -o "$output_directory/differential" --no-cache
"$output_directory/differential" > "$output_directory/actual.txt"
if ! diff -q "$cases/expected.txt" "$output_directory/actual.txt" > /dev/null; then
    echo "json differential: blocks differ from the recorded results (first inputs of each):" >&2
    diff "$cases/expected.txt" "$output_directory/actual.txt" | grep '^>' | head -10 >&2
    exit 1
fi
echo "json differential: $(wc -l < "$cases/expected.txt" | tr -d ' ') blocks of parse/reader results as recorded"
