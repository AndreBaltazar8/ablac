#!/usr/bin/env bash
# The overload probe types only the bodies that may resolve an overload or an
# operator. With ABLA_OVERLOAD_CHECK=1 the compiler also probes every body
# spelled like a candidate and fails the build if the two differ; these builds
# must pass that check and behave as before.
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_root=$project_root/build/overload-probe-filter-test
export ABLA_OVERLOAD_CHECK=1

mkdir -p "$output_root"
for program in overload-probe-filter overloads compound-assignment; do
    "$compiler" build \
        "$project_root/tests/cases/modules/$program.ab" \
        -o "$output_root/$program" --no-cache
    set +e
    "$output_root/$program"
    status=$?
    set -e
    test "$status" -eq 42
done

set +e
"$compiler" build \
    "$project_root/tests/cases/modules/overload-ambiguous.ab" \
    -o "$output_root/overload-ambiguous" --no-cache > "$output_root/ambiguous.log" 2>&1
status=$?
set -e
test "$status" -ne 0
grep -q 'call.overload-ambiguous:pick(P,Q)' "$output_root/ambiguous.log"
if grep -q 'overload.check' "$output_root/ambiguous.log"; then exit 1; fi
echo "overload probe filter: the filtered probe matches the full one"
