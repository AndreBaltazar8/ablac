#!/usr/bin/env bash
# A local or field shadows a top-level binding of its name, across modules
# (the standard library's included): reads, assignments, compile-time globals
# and threads. A call goes to the first level with a candidate that takes it,
# and when none does the error names the innermost one.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/field-shadowing"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/field-shadowing/main.ab" \
    -o "$output_directory/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
[[ $status -eq 42 ]] || { echo "field shadowing: expected 42, got $status" >&2; exit 1; }

# `import "abla/math"` brings the cos and sin the array fields are named like.
"$compiler" build "$project_root/tests/cases/field-shadowing/calls.ab" \
    -o "$output_directory/calls" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/calls" >/dev/null
status=$?
set -e
[[ $status -eq 42 ]] || { echo "field shadowing: calls expected 42, got $status" >&2; exit 1; }

if "$compiler" build "$project_root/tests/cases/field-shadowing/method-arity.ab" \
    -o "$output_directory/method-arity" --no-cache >"$output_directory/method-arity.log" 2>&1; then
    echo "field shadowing: method-arity built" >&2; exit 1
fi
grep -q 'method.arity:Counter.reset' "$output_directory/method-arity.log" ||
    { echo "field shadowing: method-arity not reported against the method" >&2
      cat "$output_directory/method-arity.log" >&2; exit 1; }
echo "field shadowing: fields shadow same-named globals across modules; calls take the first applicable level"
