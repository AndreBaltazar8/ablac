#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_root=$project_root/build/overloads-test

mkdir -p "$output_root"
"$compiler" build \
    "$project_root/tests/cases/modules/overloads.ab" \
    -o "$output_root/overloads" --no-cache
set +e
"$output_root/overloads"
status=$?
set -e
test "$status" -eq 42

set +e
"$compiler" build \
    "$project_root/tests/cases/modules/overload-ambiguous.ab" \
    -o "$output_root/overload-ambiguous" --no-cache > "$output_root/ambiguous.log" 2>&1
status=$?
set -e
test "$status" -ne 0
grep -q 'call.overload-ambiguous:pick(P,Q)' "$output_root/ambiguous.log"
echo "overloads: free/extension/method overloads, operators, ambiguity diagnostic passed"
