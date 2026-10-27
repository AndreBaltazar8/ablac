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

# Operators in parameter defaults.
"$compiler" build \
    "$project_root/tests/cases/modules/operator-defaults.ab" \
    -o "$output_root/operator-defaults" --no-cache
set +e
"$output_root/operator-defaults"
status=$?
set -e
test "$status" -eq 42

# A default that calls an overload, copied into a call that omits it.
"$compiler" build \
    "$project_root/tests/cases/modules/overload-defaults.ab" \
    -o "$output_root/overload-defaults" --no-cache
set +e
"$output_root/overload-defaults"
status=$?
set -e
test "$status" -eq 42

set +e
"$compiler" build \
    "$project_root/tests/cases/modules/overload-default-ambiguous.ab" \
    -o "$output_root/overload-default-ambiguous" --no-cache > "$output_root/default-ambiguous.log" 2>&1
status=$?
set -e
test "$status" -ne 0
grep -q 'call.overload-ambiguous:pick(P,Q)' "$output_root/default-ambiguous.log"

set +e
"$compiler" build \
    "$project_root/tests/cases/modules/overload-ambiguous.ab" \
    -o "$output_root/overload-ambiguous" --no-cache > "$output_root/ambiguous.log" 2>&1
status=$?
set -e
test "$status" -ne 0
grep -q 'call.overload-ambiguous:pick(P,Q)' "$output_root/ambiguous.log"
echo "overloads: free/extension/method overloads, operators (in parameter defaults too), overloads in defaults a call omits, ambiguity diagnostics passed"
