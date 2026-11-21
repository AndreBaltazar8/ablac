#!/usr/bin/env bash
# A global rope first read inside a region keeps its flat copy outside it (tests/cases/rope-region): three shapes of global,
# read again after the region ended and its memory was reused. Also check the private string builder's region escape and
# fallback for captured locals. Both cases build fast and for release, with and without GC stress.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/rope-region"
mkdir -p "$out"
cd "$root"
for test_case in main lowering; do
    if [[ $test_case == main ]]; then expected='rope region ok'; else expected='string building ok'; fi
    for mode in --fast ""; do
        # shellcheck disable=SC2086
        "$compiler" build "tests/cases/rope-region/$test_case.ab" -o "$out/program" $mode --no-cache \
            >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
        for stress in 0 1; do
            result=$(ABLA_GC_STRESS=$stress "$root/tools/run-limited.sh" "$out/program" 2>&1) || result="failed: $result"
            [[ $result == "$expected" ]] || { echo "$test_case (mode '$mode', stress $stress): $result" >&2; exit 1; }
        done
    done
done
echo 'rope regions and private string builders: ownership and byte checks passed'
