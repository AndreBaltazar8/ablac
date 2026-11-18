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
# The same program on one CPU shared with fourteen busy loops: the worker is often off the CPU when a stop needs it, so a
# stop that gave up after a fixed 20 ms abandoned it (every run did: 14 to 23 of about 40 stops). The stop's deadline moves by the time the
# collector itself was off the CPU, so none is abandoned; a worker that can never park is still given up on
# (tests/cases/gc-threads, blocked and stale-claim).
if command -v taskset > /dev/null; then
    cpu=$(taskset -pc $$ | sed 's/.*: *//; s/[-,].*//')
    busy=()
    for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14; do
        taskset -c "$cpu" bash -c 'while :; do :; done' &
        busy+=($!)
    done
    trap 'kill "${busy[@]}" 2> /dev/null || true' EXIT
    for run in 1 2 3; do
        status=0
        result=$(taskset -c "$cpu" "$out/spin-release" 2>&1) || status=$?
        [[ $status -eq 0 && $result == "gc spin ok:"* ]] || { echo "gc spin (one busy CPU, run $run): status $status: $result" >&2; exit 1; }
    done
    echo "gc spin (one busy CPU): 3 runs, no stop abandoned"
fi
