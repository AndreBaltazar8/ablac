#!/usr/bin/env bash
# A map's growth keeps its entry arrays when nothing was removed and compacts them when something was:
# int and string keys against a reference of two plain arrays, in fast and release builds and under
# ABLA_GC_STRESS=1 (tests/cases/map-growth).
set -euo pipefail
compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$project_root/build/map-growth"
mkdir -p "$out"
source="$project_root/tests/cases/map-growth/main.ab"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build "$source" -o "$out/program" $mode --no-cache
    set +e
    "$out/program"
    status=$?
    set -e
    [[ $status -eq 42 ]] || { echo "map growth: status $status (mode '$mode')" >&2; exit 1; }
done
set +e
ABLA_GC_STRESS=1 ABLA_GC_GROWTH=2097152 "$out/program" > "$out/stress.log" 2>&1
status=$?
set -e
[[ $status -eq 42 ]] || { echo "map growth: status $status under ABLA_GC_STRESS=1" >&2; cat "$out/stress.log" >&2; exit 1; }
echo "map growth: the entry arrays survive a rehash, compacted after removals, in every mode"
