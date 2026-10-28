#!/usr/bin/env bash
# Labeled loops (`name@ while/do/for`) left by `break@name` and continued by
# `continue@name`: at run time, at compile time, through scopes that drop
# what they own, on the right of `??`, in generators; and the diagnostics.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/labeled-loops"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/labeled-loops.ab" \
    -o "$output_directory/program" --no-cache
output=$("$project_root/tools/run-limited.sh" "$output_directory/program")
expected='nested 5012
classify negative | small 2 | seven | big
do 412
drop inner 0
leaving with branch
drop branch
drop inner 1
drop outer body
after loop keep
drop keep
drop x 0
drop x 1
drop turn 1
drop x 0
drop x 1
drop turn 2
continued
missing 2
skip 1
compile 1011
pairs 1 2 3 11 12 13 21 22 999
compile pairs 1 2 3 11 12 13 21 22 999
yield 10 11 30 31 -1'
if [[ $output != "$expected" ]]; then
    echo "labeled-loops: unexpected output:" >&2
    diff <(echo "$expected") <(echo "$output") >&2 || true
    exit 1
fi

# expect_errors <case> <diagnostic>...: the case is rejected with each one.
expect_errors() {
    local name=$1
    shift
    rm -f "$output_directory/$name"
    set +e
    "$compiler" build "$project_root/tests/cases/bootstrap/$name.ab" \
        -o "$output_directory/$name" --no-cache \
        >"$output_directory/$name-output.txt" 2>"$output_directory/$name-errors.txt"
    local status=$?
    set -e
    if [[ $status -ne 1 || -e "$output_directory/$name" ]]; then
        echo "labeled-loops: $name was accepted" >&2
        exit 1
    fi
    local diagnostic
    for diagnostic in "$@"; do
        if ! grep -Fq "$diagnostic" "$output_directory/$name-errors.txt"; then
            echo "labeled-loops: $name: missing $diagnostic" >&2
            cat "$output_directory/$name-errors.txt" >&2
            exit 1
        fi
    done
}
expect_errors invalid-loop-label-unknown \
    'break.unknown-label:other' 'continue.unknown-label:missing' \
    'break.unknown-label:outer'
expect_errors invalid-loop-label-shadowed 'loop.label-shadowed:same'

echo "labeled-loops: nested/do-block/drops/??/compile-time/generator/diagnostic checks passed"
