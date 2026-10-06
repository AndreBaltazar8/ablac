#!/usr/bin/env bash
# filledArray(count, value): one allocation of count copies; numbers, bools and
# strings only; negative counts trap; it also runs at compile time.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/array-filled"
output_directory="$project_root/build/array-filled"
mkdir -p "$output_directory"

"$compiler" build "$cases/main.ab" -o "$output_directory/main" --no-cache
"$compiler" build "$cases/trap.ab" -o "$output_directory/trap" --no-cache
set +e
"$output_directory/main"
status=$?
"$output_directory/trap" 2> /dev/null
trap_status=$?
"$compiler" build "$cases/invalid.ab" -o "$output_directory/invalid" \
    --no-cache > "$output_directory/invalid.err" 2>&1
invalid_status=$?
set -e
[[ $status -eq 42 ]] || exit 1
[[ $trap_status -ne 0 ]] || exit 1
[[ $invalid_status -ne 0 ]] || exit 1
grep -q 'filledArray.element:Node' "$output_directory/invalid.err"
grep -q 'filledArray.count' "$output_directory/invalid.err"
grep -q 'filledArray.arity' "$output_directory/invalid.err"
echo "filledArray: one allocation, value elements only, negative counts trap"
