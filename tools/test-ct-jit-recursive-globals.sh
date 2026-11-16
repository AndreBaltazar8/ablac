#!/usr/bin/env bash
# A class that refers to itself holds no closure unless one of its fields does (#972): the jit tier's ordinary-global
# analysis used to cut the search at depth 6 and decline the site of any global of a recursive class ("which may hold a
# closure"). tests/cases/ct-jit-recursive-globals/plain.ab runs natively and agrees in interp, jit and the run-time
# build; closure.ab (a recursive class with a function field) is still declined for that reason and still agrees.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/ct-jit-recursive-globals"
output_directory="$project_root/build/ct-jit-recursive-globals"
rm -rf "$output_directory"
mkdir -p "$output_directory"

run() { # $1 = case, $2 = mode, $3 = expected output
    ABLA_COMPILE_EVAL=$2 ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build "$cases/$1.ab" \
        -o "$output_directory/$1-$2" --no-cache > "$output_directory/$1-$2.trace" 2>&1 ||
        { echo "ct-jit recursive globals: $1 ($2) build failed" >&2; cat "$output_directory/$1-$2.trace" >&2; exit 1; }
    local output
    output=$("$project_root/tools/run-limited.sh" "$output_directory/$1-$2")
    [[ $output == "$3" ]] || { echo "ct-jit recursive globals: $1 ($2) printed '$output', not '$3'" >&2; exit 1; }
}

for mode in jit interp; do
    run plain "$mode" "12 0"
    run closure "$mode" "4 0"
done
if grep -q 'may hold a closure' "$output_directory/plain-jit.trace"; then
    echo "ct-jit recursive globals: the jit tier still declines the plain recursive class:" >&2
    grep 'note\[ct-jit\]' "$output_directory/plain-jit.trace" >&2
    exit 1
fi
grep -q '^note\[ct-jit\]: native at ' "$output_directory/plain-jit.trace" ||
    { echo "ct-jit recursive globals: the plain recursive class's site did not run natively" >&2; exit 1; }
grep -q 'may hold a closure' "$output_directory/closure-jit.trace" ||
    { echo "ct-jit recursive globals: a class with a function field no longer holds a closure" >&2; cat "$output_directory/closure-jit.trace" >&2; exit 1; }
echo "ct-jit recursive globals: a recursive class of plain fields runs natively; one with a function field is still declined"
