#!/usr/bin/env bash
# String equality at every length from 0 to 41 and every position of one differing byte, as `==`, `!=`
# and as map keys (tests/cases/string-equal): fast and release builds and under ABLA_GC_STRESS=1.
set -euo pipefail
compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$project_root/build/string-equal"
mkdir -p "$out"
source="$project_root/tests/cases/string-equal/main.ab"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build "$source" -o "$out/program" $mode --no-cache
    set +e
    "$out/program"
    status=$?
    set -e
    [[ $status -eq 42 ]] || { echo "string equal: status $status (mode '$mode')" >&2; exit 1; }
done
set +e
ABLA_GC_STRESS=1 ABLA_GC_GROWTH=2097152 "$out/program" > "$out/stress.log" 2>&1
status=$?
set -e
[[ $status -eq 42 ]] || { echo "string equal: status $status under ABLA_GC_STRESS=1" >&2; cat "$out/stress.log" >&2; exit 1; }
echo "string equal: right at every length and differing position, in every mode"
