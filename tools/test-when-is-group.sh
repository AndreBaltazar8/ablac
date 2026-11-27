#!/usr/bin/env bash
# An arm shared by `is` patterns only sees a nullable `when` subject not null, before the `null` arm and after it, with a
# non-nullable control; native (--fast and release) and under `#` give the same total. An arm shared with `null` stays
# nullable (decision #166).
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/when-is-group"
output_directory="$project_root/build/when-is-group"
mkdir -p "$output_directory"

expected='354315682 354315682'
for mode in release fast; do
    flags=()
    [[ $mode == fast ]] && flags=(--fast)
    "$compiler" build "$cases/main.ab" -o "$output_directory/main-$mode" "${flags[@]}"
    output=$("$output_directory/main-$mode")
    [[ $output == "$expected" ]] || { echo "when is group ($mode): $output, expected $expected"; exit 1; }
done
set +e
"$compiler" build "$cases/invalid-shared-null.ab" -o "$output_directory/invalid" > "$output_directory/invalid.err" 2>&1
invalid_status=$?
set -e
[[ $invalid_status -ne 0 ]] || { echo "when is group: an arm shared with null was narrowed"; exit 1; }
grep 'member:nullable:Shape.r' "$output_directory/invalid.err" > /dev/null ||
    { echo "when is group: unexpected diagnostics:"; cat "$output_directory/invalid.err"; exit 1; }
[[ $(grep '^error\[E_SEMANTIC\]' "$output_directory/invalid.err" | sort -u | wc -l) -eq 1 ]] ||
    { echo "when is group: expected one distinct error (a shared body is typed once per match):"; cat "$output_directory/invalid.err"; exit 1; }
echo "when is group: an arm of \`is\` patterns sees the subject not null; one shared with \`null\` does not"
