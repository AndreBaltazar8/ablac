#!/usr/bin/env bash
# A thread looping over a noescape C call with a scalar result (b6f548d65 gives such a call no memory-pressure poll) must still be
# stoppable (#1139 area 10, round 2, tests/cases/gc-native-skip): its loop keeps a safe point, so every collection of the thread that
# allocates stops the worker and none is abandoned. The peak resident size is bounded as well (about 1.5 GB of garbage is made; an
# unstoppable worker left all of it in the heap), and what the worker holds across the calls survives the collections that stop it
# (ABLA_GC_POISON=1 overwrites what a collection frees; ABLA_GC_STRESS=1 collects at every safe point; and a program built for valgrind,
# #1217, reports nothing under memcheck). The same shape as tools/test-gc-spin.sh.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'gc native skip: Linux only'; exit 0; }
out="$root/build/gc-native-skip"
rm -rf "$out"
mkdir -p "$out"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/gc-native-skip/main.ab -o "$out/skip-$mode" "${flags[@]}" > "$out/build-$mode.log" 2>&1 \
        || { cat "$out/build-$mode.log" >&2; echo "gc native skip: ($mode) did not build" >&2; exit 1; }
    status=0
    "$out/skip-$mode" > "$out/run-$mode.out" 2>&1 &
    pid=$!
    peak=0
    while kill -0 "$pid" 2> /dev/null; do
        value=$(awk '/^VmHWM:/ {print $2}' "/proc/$pid/status" 2> /dev/null || true)
        [[ -n $value ]] && peak=$value
        sleep 0.05
    done
    wait "$pid" || status=$?
    result=$(cat "$out/run-$mode.out")
    [[ $status -eq 0 && $result == "gc native skip ok:"* ]] || { echo "gc native skip ($mode): status $status: $result" >&2; exit 1; }
    [[ $peak -lt 600000 ]] || { echo "gc native skip ($mode): peak resident size $peak kB, the worker held up the collector" >&2; exit 1; }
    echo "gc native skip ($mode): $result, peak ${peak} kB"
done
# The held objects under poison and under stress (fewer rounds: every safe point collects).
for variant in "ABLA_GC_POISON=1 ABLA_SKIP_ROUNDS=300 ABLA_SKIP_SECONDS=3" "ABLA_GC_STRESS=1 ABLA_SKIP_ROUNDS=4 ABLA_SKIP_SECONDS=3"; do
    status=0
    result=$(env $variant "$out/skip-fast" 2>&1) || status=$?
    [[ $status -eq 0 && $result == "gc native skip ok:"* ]] || { echo "gc native skip ($variant): status $status: $result" >&2; exit 1; }
    echo "gc native skip ($variant): $result"
done
# Under memcheck (a build for valgrind: the runtime tells it about its heap).
if command -v valgrind > /dev/null; then
    "$compiler" build tests/cases/gc-native-skip/main.ab -o "$out/skip-valgrind" --fast -g --valgrind --no-cache > "$out/build-valgrind.log" 2>&1 \
        || { cat "$out/build-valgrind.log" >&2; echo 'gc native skip: (valgrind) did not build' >&2; exit 1; }
    status=0
    ABLA_SKIP_ROUNDS=40 ABLA_SKIP_SECONDS=3 timeout 600 valgrind --error-exitcode=9 --suppressions="$root/tools/valgrind.supp" \
        --log-file="$out/valgrind.log" "$out/skip-valgrind" > "$out/valgrind.out" 2>&1 || status=$?
    [[ $status -eq 0 ]] && grep -q 'ERROR SUMMARY: 0 errors' "$out/valgrind.log" ||
        { echo "gc native skip (valgrind): status $status: $(grep -m3 -E 'Invalid|uninitialised|ERROR SUMMARY' "$out/valgrind.log")" >&2; exit 1; }
    echo "gc native skip (valgrind): $(cat "$out/valgrind.out")"
elif [[ -n ${ABLAC_DEV_SHELL:-} ]]; then
    echo 'gc native skip: no valgrind in the development shell' >&2; exit 1
fi
