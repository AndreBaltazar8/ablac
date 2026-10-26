#!/usr/bin/env bash
# A lambda's number counts the functions lowered in its owner before it, not
# in the program. A function and its use added in another module, lowered
# first, leave every symbol the program had: the lambdas of globals'
# initializers were numbered by every function lowered before them, so they
# were all renamed.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $compiler != /* ]]; then compiler="$project_root/$compiler"; fi
output_directory="$project_root/build/lambda-ordinal"
rm -rf "$output_directory"
mkdir -p "$output_directory"

fail() {
    echo "lambda ordinal: $1" >&2
    exit 1
}

for build in plain added; do
    work="$output_directory/$build"
    mkdir -p "$work"
    cp -R "$project_root/tests/cases/lambda-ordinal/." "$work/"
    if [[ $build == added ]]; then
        {
            printf 'fun addedElsewhere(): int { val h = { x: int -> x * 2 }; return h(2) }\n'
            sed 's/^fun otherValue(): int = 7$/fun otherValue(): int = addedElsewhere() + 3/' "$work/other.ab"
        } > "$work/other.next"
        mv "$work/other.next" "$work/other.ab"
        grep -q 'addedElsewhere() + 3' "$work/other.ab" || fail "the edit didn't apply"
    fi
    (cd "$work" && "$compiler" --emit-llvm main.ab > "$work/main.ll")
    sed -n 's/^define [^@]*@\([^(]*\)(.*/\1/p' "$work/main.ll" | sort -u > "$work/symbols"
    "$compiler" build "$work/main.ab" -o "$work/main" --no-cache
    set +e
    "$work/main" > "$work/output" 2>&1
    echo "status $?" >> "$work/output"
    set -e
done
[[ $(cat "$output_directory/plain/output") == $'2 34 6 7 9 7\nstatus 42' ]] ||
    fail "unexpected output: $(cat "$output_directory/plain/output")"
cmp -s "$output_directory/plain/output" "$output_directory/added/output" ||
    fail "the output changed with the added function"
[[ $(wc -l < "$output_directory/plain/symbols") -gt 0 ]] || fail "no symbols defined"
missing=$(comm -23 "$output_directory/plain/symbols" "$output_directory/added/symbols")
[[ -z $missing ]] || fail "symbols renamed by a function added in another module: $missing"
echo "lambda ordinal: a function added in another module renames no lambda"
