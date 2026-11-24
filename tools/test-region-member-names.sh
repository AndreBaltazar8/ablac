#!/usr/bin/env bash
# A member call in a region is checked against the declaration it resolves to (#827): two unrelated classes with a
# method `dispatch`, one of which stores what it is given in a module value. A region may call the other's, directly,
# through `this`, a field, an array element, a typed binding and a call (allowed.ab exits 46).
# The storing one is still refused, including a shadowing local and an interface call.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/region-member-names"
output_directory="$project_root/build/region-member-names"
rm -rf "$output_directory"
mkdir -p "$output_directory"

"$compiler" build "$cases/allowed.ab" -o "$output_directory/allowed"
status=0
"$project_root/tools/run-limited.sh" "$output_directory/allowed" || status=$?
[[ $status == 46 ]] ||
    { echo "region member names: allowed exited $status, not 46" >&2; exit 1; }

if "$compiler" build "$cases/refused.ab" -o "$output_directory/refused" \
    > "$output_directory/refused.err" 2>&1; then
    echo "region member names: refused.ab compiled" >&2; exit 1
fi
for member in dispatch store storeParameter shadowed storeDynamic storeFromFactory shadowedFactory storeThroughGlobal shadowGlobal storeInField storeThroughExtensionField; do
    count=$(grep -cxF "error[E_SEMANTIC]: region.call-retention:$member" "$output_directory/refused.err" || true)
    [[ $count == 1 ]] ||
        { echo "region member names: expected one refusal of $member, got $count" >&2
          cat "$output_directory/refused.err" >&2; exit 1; }
done
echo "region member names: a region calls a method by its resolved declaration; the retaining one of the same name is refused"
