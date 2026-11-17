#!/usr/bin/env bash
# A thread spinning in a loop that allocates nothing must not hold up the collector (#811, tests/cases/gc-spin): the loop's
# back edge has a safe point because it reads an atomic word, so every stop parks the worker and none is abandoned. The
# peak resident size is bounded as well (about 3 GB of garbage is made; an unstoppable worker left all of it in the heap).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'gc spin: Linux only'; exit 0; }
out="$root/build/gc-spin"
rm -rf "$out"
mkdir -p "$out"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/gc-spin/main.ab -o "$out/spin-$mode" "${flags[@]}" > "$out/build-$mode.log" 2>&1 \
        || { cat "$out/build-$mode.log" >&2; echo "gc spin: ($mode) did not build" >&2; exit 1; }
    status=0
    "$out/spin-$mode" > "$out/run-$mode.out" 2>&1 &
    pid=$!
    peak=0
    while kill -0 "$pid" 2> /dev/null; do
        value=$(awk '/^VmHWM:/ {print $2}' "/proc/$pid/status" 2> /dev/null || true)
        [[ -n $value ]] && peak=$value
        sleep 0.05
    done
    wait "$pid" || status=$?
    result=$(cat "$out/run-$mode.out")
    [[ $status -eq 0 && $result == "gc spin ok:"* ]] || { echo "gc spin ($mode): status $status: $result" >&2; exit 1; }
    # 1.5 GB of garbage at 1 MB a string; a collecting heap stays far below it
    [[ $peak -lt 600000 ]] || { echo "gc spin ($mode): peak resident size $peak kB, the worker held up the collector" >&2; exit 1; }
    echo "gc spin ($mode): $result, peak ${peak} kB"
done
