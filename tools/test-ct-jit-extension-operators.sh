#!/usr/bin/env bash
# The jit tier's ordinary-global write analysis resolves an operator that is an extension function through the
# checker (#828): `secretU64 - secretU64` reaches abla/ct's secretU64.minus alone, not every `minus` (here a class's
# that appends to a module value), so the compile-time site runs natively instead of being declined. Both tiers and
# the run-time build print the same line.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case_directory="$project_root/tests/cases/ct-jit-extension-operators"
output_directory="$project_root/build/ct-jit-extension-operators"
rm -rf "$output_directory"
mkdir -p "$output_directory"

for mode in jit interp; do
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build "$case_directory/main.ab" \
        -o "$output_directory/$mode" --no-cache > "$output_directory/$mode.trace" 2>&1 ||
        { echo "ct-jit extension operators: $mode build failed" >&2; cat "$output_directory/$mode.trace" >&2; exit 1; }
    output=$("$project_root/tools/run-limited.sh" "$output_directory/$mode")
    [[ $output == "2 5 1" ]] ||
        { echo "ct-jit extension operators: $mode printed '$output', not '2 5 1'" >&2; exit 1; }
done
if grep -q 'may be written at' "$output_directory/jit.trace"; then
    echo "ct-jit extension operators: the jit tier still declines the site:" >&2
    grep 'note\[ct-jit\]' "$output_directory/jit.trace" >&2
    exit 1
fi
grep -q '^note\[ct-jit\]: native at ' "$output_directory/jit.trace" ||
    { echo "ct-jit extension operators: no site ran natively" >&2; grep 'note\[ct-jit\]' "$output_directory/jit.trace" >&2; exit 1; }
echo "ct-jit extension operators: an extension operator is followed to its one declaration; the site runs natively"
