#!/usr/bin/env bash
# Integer text is right for every width and the edges of the digit counts and of the
# allocation-free table of small numbers (tests/cases/int-text): natively (fast and release
# builds) and under `#`, against a reference written in plain Abla. A copy whose staged
# side prints one more must fail.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/int-text"
mkdir -p "$output_directory"
source="$project_root/tests/cases/int-text/main.ab"

for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build "$source" -o "$output_directory/program" $mode --no-cache
    set +e
    "$output_directory/program"
    status=$?
    set -e
    [[ $status -eq 42 ]] || { echo "int-text: status $status (mode '$mode')" >&2; exit 1; }
done

mutated="$output_directory/mutated.ab"
awk '/^compile fun staged/ { inside = 1 } inside && /out.append\("\$\{x\}"\)/ && !done { sub(/\$\{x\}/, "${x + 1}"); done = 1 } { print }' \
    "$source" > "$mutated"
cmp -s "$mutated" "$source" && { echo "int-text: the negative control changed nothing" >&2; exit 1; }
"$compiler" build "$mutated" -o "$output_directory/mutated" --fast --no-cache
set +e
"$output_directory/mutated" > "$output_directory/mutated.log" 2>&1
status=$?
set -e
[[ $status -eq 1 ]] && grep -q 'staged' "$output_directory/mutated.log" ||
    { echo "int-text: the negative control was not caught" >&2; exit 1; }
echo "int text: right for every width, the small-number table and the digit-count edges"
