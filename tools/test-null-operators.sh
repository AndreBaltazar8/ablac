#!/usr/bin/env bash
# `?.` and `??`: the program checks chains, skipped arguments, lazy defaults,
# grouping, `?? return`/`break`/`continue` and the same under `#`; each
# fixture is one mistake with one error naming it.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/null-operators"
mkdir -p "$output_directory"
cases="$project_root/tests/cases/modules"

"$compiler" build "$cases/null-operators.ab" -o "$output_directory/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "null operators: program expected 42, got $status" >&2
    exit 1
fi

check() { # file count expected… (count = number of `error[` lines)
    local file=$1 count=$2 status errors diagnostics; shift 2
    set +e
    diagnostics=$("$compiler" build "$cases/$file.ab" -o "$output_directory/$file" --no-cache 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 ]] || { echo "$file: built"; exit 1; }
    errors=$(grep -c '^error\[' <<<"$diagnostics" || true)
    [[ $errors -eq $count ]] || { echo "$file: $errors errors, expected $count"; echo "$diagnostics"; exit 1; }
    for text in "$@"; do
        [[ $diagnostics == *"$text"* ]] || { echo "$file: missing '$text'"; echo "$diagnostics"; exit 1; }
    done
}

check invalid-safe-call 1 "safe-call.non-null:M" "use \`.\`"
check invalid-null-default-non-null 1 "null-default.non-null:i64"
check invalid-null-default-type 1 "null-default.type:string:i64"
check invalid-safe-call-assignment 1 "E_PARSE_ASSIGNMENT_TARGET" "a \`?.\` chain is not assignable"
check invalid-null-default-resource 1 "ownership.move-required" "\`move(a) ?? b\`"
check invalid-elvis-template 1 "E_PARSE_ELVIS" "as \`??\`"

echo "null operators: ?. chains, ?? defaults, precedence, leaving defaults, # parity, diagnostics"
