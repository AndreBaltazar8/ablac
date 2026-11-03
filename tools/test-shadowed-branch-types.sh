#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/shadowed-branch-types"
mkdir -p "$out"
for profile in fast release; do
    flags=()
    [[ $profile != fast ]] || flags=(--fast)
    "$compiler" build "$root/tests/cases/shadowed-branch-types/main.ab" -o "$out/$profile" "${flags[@]}" --no-cache
    for stress in 0 1; do
        status=0
        ABLA_GC_STRESS=$stress "$out/$profile" || status=$?
        [[ $status -eq 42 ]] || { echo "shadowed branches ($profile, GC stress $stress) failed: $status" >&2; exit 1; }
    done
done
for fixture in invalid-if-move invalid-array-move; do
    if "$compiler" build "$root/tests/cases/shadowed-branch-types/$fixture.ab" -o "$out/$fixture" --fast --no-cache >"$out/$fixture.log" 2>&1; then
        echo "$fixture unexpectedly compiled" >&2; exit 1
    fi
    grep -q 'ownership.move-required' "$out/$fixture.log" || { cat "$out/$fixture.log" >&2; exit 1; }
done
if "$compiler" build "$root/tests/cases/shadowed-branch-types/invalid-borrowed-resource.ab" -o "$out/invalid-borrowed-resource" --fast --no-cache >"$out/invalid-borrowed-resource.log" 2>&1; then
    echo 'invalid-borrowed-resource unexpectedly compiled' >&2; exit 1
fi
grep -q 'ownership.borrow-escape' "$out/invalid-borrowed-resource.log" || { cat "$out/invalid-borrowed-resource.log" >&2; exit 1; }
echo 'shadowed if and when arms preserve local types and resource drops'
