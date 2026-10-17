#!/usr/bin/env bash
# Named arguments on methods and extension functions: defaults read the
# receiver's fields, the receiver and arguments are evaluated once in order,
# at run time and under `#`; a named method call whose candidates disagree is
# a clear error.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/named-method-arguments"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/named-method-arguments.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$output_directory/program"
status=$?
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-named-method-arguments.ab" \
    > "$output_directory/invalid.ll" 2> "$output_directory/invalid.err"
invalid=$?
set -e
[[ $status -eq 42 && $invalid -ne 0 ]] || { cat "$output_directory/invalid.err" >&2; exit 1; }
err=$output_directory/invalid.err
grep -q 'named call `scaled` matches methods whose parameters differ' "$err"
grep -q 'named call `weighed` has no method or extension with those parameters' "$err"
grep -q 'named call `mixed` matches methods whose default for `b` differs' "$err"
[[ $(grep -c '^error\[E_NAMED_ARGUMENT_TARGET\]' "$err") -eq 3 ]] || { cat "$err" >&2; exit 1; }
echo "named method arguments: receiver defaults, order, and ambiguity errors"
