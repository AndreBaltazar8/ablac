#!/usr/bin/env bash
# One mistake, one error, with the fix named: an unknown method is
# method.unknown (with the import that declares it), `?.` on a value that is
# never null and Kotlin's `?:` get one error each, and a defer body may end in
# an assignment. A `{ ... }` statement whose value is dropped is an error (#824); a
# lambda that is a block's value is not.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/diagnostic-hints"
mkdir -p "$output_directory"
cases="$project_root/tests/cases/modules"

check() { # file count expected… (count = number of `error[` lines)
    local file=$1 count=$2 status errors; shift 2
    set +e
    diagnostics=$("$compiler" build "$cases/$file.ab" -o "$output_directory/$file" 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 ]] || { echo "$file: built"; exit 1; }
    errors=$(grep -c '^error\[' <<<"$diagnostics" || true)
    [[ $errors -eq $count ]] || { echo "$file: $errors errors, expected $count"; echo "$diagnostics"; exit 1; }
    for text in "$@"; do
        [[ $diagnostics == *"$text"* ]] || { echo "$file: missing '$text'"; echo "$diagnostics"; exit 1; }
    done
}

check invalid-method-unknown 1 "method.unknown:string.fooBar"
check invalid-method-missing-import 1 "method.unknown:string.trim" 'help: `trim` is declared in abla/text; add `import "abla/text"`'
check invalid-method-unknown-template 1 "method.unknown:C.fooBar"
check invalid-safe-call 1 "safe-call.non-null:M"
check invalid-unknown-in-arithmetic 1 "identifier:x"
check invalid-elvis-template 1 "E_PARSE_ELVIS" "Abla writes Kotlin's \`?:\` as \`??\`"
# A `{ ... }` statement whose value is dropped never runs (#824): one error each, with the fix named.
check invalid-discarded-lambda 6 "E_PARSE_DISCARDED_LAMBDA" 'help: to run the statements here, write `if (true) { ... }`'

"$compiler" build "$cases/defer-assignment-tail.ab" -o "$output_directory/defer-assignment-tail" >/dev/null
actual=$("$output_directory/defer-assignment-tail")
[[ $actual == "1 x 2 3" ]] || { echo "defer-assignment-tail: '$actual'"; exit 1; }
"$compiler" build "$cases/trailing-lambda-member-call.ab" -o "$output_directory/trailing-lambda-member-call" >/dev/null
actual=$("$output_directory/trailing-lambda-member-call")
[[ $actual == "30 11 101 0" ]] || { echo "trailing-lambda-member-call: '$actual'"; exit 1; }
"$compiler" build "$cases/lambda-block-values.ab" -o "$output_directory/lambda-block-values" >/dev/null
actual=$("$output_directory/lambda-block-values")
[[ $actual == "21 second inner 1" ]] || { echo "lambda-block-values: '$actual'"; exit 1; }
echo "diagnostic hints: method.unknown (+ import), ?. and ?:, defer ending in an assignment, trailing lambda after a member call, a dropped { ... } statement"
