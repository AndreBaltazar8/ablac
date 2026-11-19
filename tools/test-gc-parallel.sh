#!/usr/bin/env bash
# The parallel mark (ABLA_GC_WORKERS=n, stdlib/abla/runtime/platform/host.ab): a collection's mark on 2, 4 and 8 threads gives the
# serial mark's result. tests/cases/gc-parallel: a graph with much sharing (an object two threads reach at once is claimed once:
# a second claim traps), a frozen group that many live objects point at (its reached flag is set by every thread that finds it),
# garbage made between collections. Run release and --fast, at 2, 4 and 8 threads, under ABLA_GC_STRESS=1 (a collection at every
# safe point, on a small graph), the frozen graph test at 4 threads under stress, and on one CPU shared with busy loops (the
# threads must not make a collection worse than serial there). ABLA_GC_TRACE=1 shows the work each thread did
# ("gc: parallel mark, objects by thread: ..."): the run at 4 threads must show every thread working.
# The sweep (tests/cases/gc-parallel/sweep.ab): see the block in the loop. Mutation checks of the sweep (by hand, 2026-11-19): a header index off by one,
# a kept object's mark not cleared and a kept entry moved to the wrong slot each end under ABLA_GC_STRESS=1 (the registry check traps, or the
# program sees damaged strings or crashes).
# Mutation checks (by hand): the claim as a load, a delay and a store, not the compare-and-swap, traps ("Illegal instruction") on
# the first collection; the group's flag set by a toggle, not a store of 1, ends in a segmentation fault (the group is freed).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'gc parallel: Linux only'; exit 0; }
out=build/gc-parallel
rm -rf "$out"
mkdir -p "$out"
fail() { echo "gc parallel: $1" >&2; exit 1; }
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/gc-parallel/main.ab -o "$out/main.$mode" "${flags[@]}" > "$out/main.$mode.build" 2>&1 \
        || { cat "$out/main.$mode.build" >&2; fail "main ($mode) did not build"; }
    "$compiler" build tests/cases/frozen/graph.ab -o "$out/graph.$mode" "${flags[@]}" > "$out/graph.$mode.build" 2>&1 \
        || { cat "$out/graph.$mode.build" >&2; fail "graph ($mode) did not build"; }
    serial=$(ABLA_GC_WORKERS=0 "$root/tools/run-limited.sh" "$out/main.$mode" 2>&1) || fail "serial ($mode) failed: $serial"
    [[ $serial == "gc parallel ok:"* ]] || fail "serial ($mode): $serial"
    for workers in 2 4 8; do
        status=0
        result=$(ABLA_GC_WORKERS=$workers ABLA_GC_TRACE=1 "$root/tools/run-limited.sh" "$out/main.$mode" 2>&1 | tr -d "\\0") || status=$?
        [[ $status -eq 0 && $result == *"$serial"* ]] || fail "$workers threads ($mode) failed ($status): ${result: -300}"
        threads=$(printf '%s\n' "$result" | grep -a 'gc: parallel mark, objects' | tail -n 1)
        [[ -n $threads ]] || fail "$workers threads ($mode): no parallel mark ran"
        if [[ $workers == 4 ]]; then
            busy=$(printf '%s\n' "${threads##*thread:}" | awk '{c = 0; for (i = 1; i <= NF; i++) if ($i + 0 > 0) c++; print c}')
            [[ $busy -ge 3 ]] || fail "4 threads ($mode): only $busy took part: $threads"
        fi
    done
    for workers in 2 4; do
        status=0
        result=$(ABLA_GC_WORKERS=$workers ABLA_GC_STRESS=1 "$root/tools/run-limited.sh" "$out/main.$mode" 9000 2>&1) || status=$?
        [[ $status -eq 0 && $result == "gc parallel ok:"* ]] || fail "$workers threads under stress ($mode) failed ($status): ${result: -300}"
    done
    status=0
    result=$(ABLA_GC_WORKERS=4 ABLA_GC_STRESS=1 "$root/tools/run-limited.sh" "$out/graph.$mode" 2>&1) || status=$?
    [[ $status -eq 0 && $result == *"frozen graph ok"* ]] || fail "frozen graph, 4 threads under stress ($mode) failed ($status): ${result: -300}"
    # The parallel sweep with uneven slices (tests/cases/gc-parallel/sweep.ab: garbage then live, live then garbage, alternating): the
    # result of every worker count is the serial one, the trace shows the sweep ran in parallel, and under stress each parallel sweep
    # checks that every kept header's index is its slot (a trap otherwise).
    "$compiler" build tests/cases/gc-parallel/sweep.ab -o "$out/sweep.$mode" "${flags[@]}" > "$out/sweep.$mode.build" 2>&1 \
        || { cat "$out/sweep.$mode.build" >&2; fail "sweep ($mode) did not build"; }
    serial=$(ABLA_GC_WORKERS=0 "$root/tools/run-limited.sh" "$out/sweep.$mode" 2>&1) || fail "sweep serial ($mode) failed: $serial"
    [[ $serial == "gc parallel sweep ok:"* ]] || fail "sweep serial ($mode): $serial"
    for workers in 2 4 8; do
        status=0
        result=$(ABLA_GC_WORKERS=$workers ABLA_GC_TRACE=1 "$root/tools/run-limited.sh" "$out/sweep.$mode" 2>&1 | tr -d "\\0") || status=$?
        [[ $status -eq 0 && $result == *"$serial"* ]] || fail "sweep, $workers threads ($mode) failed ($status): ${result: -300}"
        [[ $result == *"gc: parallel sweep, slots"* ]] || fail "sweep, $workers threads ($mode): no parallel sweep ran"
    done
    for workers in 2 4; do
        status=0
        result=$(ABLA_GC_WORKERS=$workers ABLA_GC_STRESS=1 "$root/tools/run-limited.sh" "$out/sweep.$mode" 400 2>&1 | tr -d "\\0") || status=$?
        [[ $status -eq 0 && $result == "gc parallel sweep ok:"* ]] || fail "sweep, $workers threads under stress ($mode) failed ($status): ${result: -300}"
    done
    echo "gc parallel ($mode): 2, 4 and 8 threads equal the serial mark and sweep; stress and the frozen graph pass"
done
# One CPU shared with busy loops: the threads run beside the loops and must finish in about the serial time.
if command -v taskset > /dev/null; then
    cpu=$(taskset -pc $$ | sed 's/.*: *//; s/[-,].*//')
    hogs=()
    for _ in 1 2 3 4; do
        taskset -c "$cpu" bash -c 'while :; do :; done' &
        hogs+=($!)
    done
    trap 'kill "${hogs[@]}" 2> /dev/null || true' EXIT
    for workers in 0 4; do
        start=$(date +%s)
        status=0
        result=$(ABLA_GC_WORKERS=$workers taskset -c "$cpu" "$root/tools/run-limited.sh" "$out/main.release" 200000 2>&1) || status=$?
        [[ $status -eq 0 && $result == "gc parallel ok:"* ]] || fail "one busy CPU, $workers threads failed ($status): ${result: -300}"
        seconds[workers]=$(( $(date +%s) - start ))
    done
    # Serial plus a third: the extra threads share the one CPU and only add their start-up and their waiting.
    (( ${seconds[4]} * 3 <= ${seconds[0]} * 4 + 6 )) || fail "one busy CPU: 4 threads took ${seconds[4]} s, serial ${seconds[0]} s"
    echo "gc parallel (one busy CPU): serial ${seconds[0]} s, 4 threads ${seconds[4]} s"
fi
echo 'gc parallel: the parallel mark passes (threads, stress, the frozen graph, one busy CPU)'
