#!/usr/bin/env bash
# A `when` on a nullable name narrows it to its non-null type in the arms after
# its `null ->` arm, at runtime and under `#`; the arms before it are not narrowed.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/when-null"
output_directory="$project_root/build/when-null"
mkdir -p "$output_directory"

"$compiler" build "$cases/main.ab" -o "$output_directory/main" --no-cache
set +e
output=$("$output_directory/main")
status=$?
"$compiler" build "$cases/invalid-before-null.ab" -o "$output_directory/invalid" \
    --no-cache > "$output_directory/invalid.err" 2>&1
invalid_status=$?
set -e
expected='none letter a 1 other:xyz b or none 5 -1 42 100
other:xyz 3 2'
[[ $status -eq 42 && $output == "$expected" ]] || {
    echo "when null: status $status, output:"; echo "$output"; exit 1
}
[[ $invalid_status -ne 0 ]] || exit 1
grep -q 'member:nullable:string.size' "$output_directory/invalid.err"
[[ $(grep -c '^error\[E_SEMANTIC\]' "$output_directory/invalid.err") -eq 1 ]]
echo "when null: the arms after \`null ->\` see the subject not null"
