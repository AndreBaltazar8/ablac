#!/usr/bin/env bash
# Array truncate/clear: in place, capacity kept, out-of-range counts trap, and
# the receiver must be an owned, mutable array.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/array-truncate"
output_directory="$project_root/build/array-truncate"
mkdir -p "$output_directory"

"$compiler" build "$cases/main.ab" -o "$output_directory/main" --no-cache
"$compiler" build "$cases/trap.ab" -o "$output_directory/trap" --no-cache
set +e
"$output_directory/main"
status=$?
"$output_directory/trap" 2> /dev/null
trap_status=$?
"$compiler" build "$cases/invalid-borrowed.ab" -o "$output_directory/invalid" \
    --no-cache > "$output_directory/borrowed.err" 2>&1
borrowed_status=$?
"$compiler" build "$cases/invalid-size.ab" -o "$output_directory/invalid" \
    --no-cache > "$output_directory/size.err" 2>&1
size_status=$?
set -e
[[ $status -eq 42 ]] || exit 1
[[ $trap_status -ne 0 ]] || exit 1
[[ $borrowed_status -ne 0 && $size_status -ne 0 ]] || exit 1
grep -q 'ownership.borrow-mutation:clear' "$output_directory/borrowed.err"
grep -q 'truncate.size' "$output_directory/size.err"
grep -q 'clear.arity' "$output_directory/size.err"
echo "array truncate/clear: in place, trapping past the end, owned receivers only"
