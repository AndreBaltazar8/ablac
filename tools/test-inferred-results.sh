#!/usr/bin/env bash
# Functions, methods, extensions and compile funs without a declared result type
# have the type of their bodies: callers use it like a declared one, at runtime
# and under `#`, and a cycle of them is reported where it closes.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/inferred-results"
output_directory="$project_root/build/inferred-results"
mkdir -p "$output_directory"

"$compiler" build "$cases/main.ab" -o "$output_directory/main" --no-cache
set +e
output=$("$output_directory/main")
status=$?
"$compiler" build "$cases/invalid-cycle.ab" -o "$output_directory/invalid" \
    --no-cache > "$output_directory/cycle.err" 2>&1
cycle_status=$?
"$compiler" build "$cases/invalid-mutual-cycle.ab" -o "$output_directory/invalid" \
    --no-cache > "$output_directory/mutual.err" 2>&1
mutual_status=$?
set -e
expected='box5 10 15 2.5
2 b 0.25 3
pos
7 4 6
6 2 small big true
40 3 5 10
true false int 3 string x
13 x3 12 s3 true 12
8 2 true int 2 small|8 2 true int 2 small|42|6'
[[ $status -eq 42 && $output == "$expected" ]] || {
    echo "inferred results: status $status, output:"; echo "$output"; exit 1
}
[[ $cycle_status -ne 0 && $mutual_status -ne 0 ]] || exit 1
grep -q 'function.result-cycle:fact@42' "$output_directory/cycle.err"
grep -q 'invalid-cycle.ab:42:43' "$output_directory/cycle.err"
grep -q 'give it a result type' "$output_directory/cycle.err"
[[ $(grep -c 'function.result-cycle' "$output_directory/cycle.err") -eq 1 ]]
grep -q 'function.result-cycle:pong@38' "$output_directory/mutual.err"
grep -q 'function.result-cycle:walk@' "$output_directory/mutual.err"
[[ $(grep -c '^error' "$output_directory/mutual.err") -eq 2 ]]
echo "inferred results: callers use the body's type; cycles are named where they close"
