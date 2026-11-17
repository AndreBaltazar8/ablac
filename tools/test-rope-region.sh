#!/usr/bin/env bash
# A global rope first read inside a region keeps its flat copy outside it (tests/cases/rope-region): three shapes of global,
# read again after the region ended and its memory was reused; fast and release builds, with and without GC stress.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/rope-region"
mkdir -p "$out"
cd "$root"
for mode in --fast ""; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/rope-region/main.ab -o "$out/program" $mode --no-cache \
        >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
    for stress in 0 1; do
        result=$(ABLA_GC_STRESS=$stress "$root/tools/run-limited.sh" "$out/program" 2>&1) || result="failed: $result"
        [[ $result == "rope region ok" ]] || { echo "rope region (mode '$mode', stress $stress): $result" >&2; exit 1; }
    done
done
echo 'rope region: a global rope first read inside a region reads whole after the region ends'
