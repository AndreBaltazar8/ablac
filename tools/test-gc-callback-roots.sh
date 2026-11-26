#!/usr/bin/env bash
# C calls an Abla function that allocates, through a pointer (bsearch's comparator, nativeFunctionAddress), while the caller holds
# strings, an array and an object across the call (#1139 area 10, #1279, tests/cases/gc-callback-roots): the collector runs inside the
# call, and what the caller holds must still be there after it: plain, with ABLA_GC_POISON=1 (a collection overwrites what it frees),
# with ABLA_GC_STRESS=1 (a collection at every safe point) and with both, in a release and a --fast build.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'gc callback roots: Linux only'; exit 0; }
out="$root/build/gc-callback-roots"
rm -rf "$out"
mkdir -p "$out"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/gc-callback-roots/main.ab -o "$out/roots-$mode" "${flags[@]}" > "$out/build-$mode.log" 2>&1 \
        || { cat "$out/build-$mode.log" >&2; echo "gc callback roots: ($mode) did not build" >&2; exit 1; }
    for variant in "ABLA_GC_X=0" "ABLA_GC_POISON=1" "ABLA_GC_STRESS=1" "ABLA_GC_POISON=1 ABLA_GC_STRESS=1"; do
        status=0
        result=$(env $variant timeout 300 "$out/roots-$mode" 2>&1) || status=$?
        [[ $status -eq 0 && $result == "gc callback roots ok:"* ]] ||
            { echo "gc callback roots ($mode, $variant): status $status: $(echo "$result" | head -3)" >&2; exit 1; }
    done
    echo "gc callback roots ($mode): $result"
done
