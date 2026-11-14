#!/usr/bin/env bash
# Scalars carry no global's origins in the jit tier's ordinary-global write analysis (#829): an int read from a
# read-only table, appended to an array and stored in a field, does not make the assignment of a fresh object's int
# field a write of the table (http/event's acceptReady was declined through deflateLengthBases that way). The site in
# tests/cases/ct-jit-scalar-flows runs natively, and interp, jit and the run-time build print the same line.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_file="$project_root/tests/cases/ct-jit-scalar-flows/main.ab"
output_directory="$project_root/build/ct-jit-scalar-flows"
rm -rf "$output_directory"
mkdir -p "$output_directory"

for mode in jit interp; do
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build "$source_file" \
        -o "$output_directory/$mode" --no-cache > "$output_directory/$mode.trace" 2>&1 ||
        { echo "ct-jit scalar flows: $mode build failed" >&2; cat "$output_directory/$mode.trace" >&2; exit 1; }
    output=$("$project_root/tools/run-limited.sh" "$output_directory/$mode")
    [[ $output == "12 5" ]] || { echo "ct-jit scalar flows: $mode printed '$output', not '12 5'" >&2; exit 1; }
done
if grep -q 'may be written at' "$output_directory/jit.trace"; then
    echo "ct-jit scalar flows: the jit tier still declines the site:" >&2
    grep 'note\[ct-jit\]' "$output_directory/jit.trace" >&2
    exit 1
fi
grep -q '^note\[ct-jit\]: native at ' "$output_directory/jit.trace" ||
    { echo "ct-jit scalar flows: no site ran natively" >&2; exit 1; }
echo "ct-jit scalar flows: scalars read from a global carry none of its origins; the site runs natively"
