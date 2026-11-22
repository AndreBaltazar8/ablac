#!/usr/bin/env bash
# tools/test-ct-threads-heap.sh under GC stress (#1128). That test's 32 builds with ABLA_GC_STRESS=1 on the whole compiler do
# not fit a 600 s lease (one build of a three-round site does not finish in 270 s: the compiler's own work collects at every
# safe point). Here the same site (tests/cases/ct-threads-heap/stress.ab: eighty rounds of eight threads, as main.ab) turns
# stress on for its own runtime while its threads start and allocate, and the compiler runs the call with its heap under
# stress too (ABLA_COMPILER_GC_STRESS=ct, src/gc_stress_scope.ab). Eight builds at once on two CPUs, twice; every one must
# finish, agree with run time, report its runtime's collections (not zero) and open the compiler's window. The site's code
# runs on its own runtime and heap, and only its threads' emulated thread-locals come from the compiler's heap, so that
# window may see no collection of the compiler's heap: its count is reported, not required.
#
# Mutation check (2026-11-22): without the shared heap before a threaded generation's call (ct_eval.ab, bootstrapCtCall:
# runtimeMemoryEnableSharing) a build stops with an illegal instruction or hangs (until its 90 s limit), in 4 runs of 4.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
out="$project_root/build/ct-threads-heap-stress"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-threads-heap"
cpus=$(nproc)
pin=()
if command -v taskset >/dev/null && (( cpus > 2 )); then pin=(taskset -c 0,1); fi
compiler_collections=0
pids=()
# A failed build ends the test: stop the builds still running beside it (each leads its own process group).
trap 'for pid in "${pids[@]}"; do kill -- "-$pid" 2>/dev/null || true; done; wait 2>/dev/null || true' EXIT
for round in 1 2; do
    pids=()
    for k in 1 2 3 4 5 6 7 8; do
        ABLA_MAX_SECONDS=90 ABLA_COMPILER_GC_STRESS=ct ABLA_COMPILE_EVAL=jit setsid "${pin[@]}" "$compiler" build stress.ab -o "$out/p-$round-$k" \
            --fast --no-cache > "$out/b-$round-$k.log" 2>&1 & pids+=($!)
    done
    for k in 1 2 3 4 5 6 7 8; do
        wait "${pids[$((k - 1))]}" || { cat "$out/b-$round-$k.log" >&2; echo "ct threads heap stress: build $round-$k failed" >&2; exit 1; }
        window=$(tr -d '\0' < "$out/b-$round-$k.log" | awk '$1 == "abla-gc-stress" && $2 == "ct" { print $4; exit }')
        if [[ -z $window ]]; then
            cat "$out/b-$round-$k.log" >&2
            echo "ct threads heap stress: build $round-$k opened no stressed window for the call" >&2
            exit 1
        fi
        compiler_collections=$((compiler_collections + window))
        read -r runtime compiled site_collections < <("$out/p-$round-$k")
        if [[ $runtime != "$compiled" || $runtime -le 0 ]]; then
            echo "ct threads heap stress: build $round-$k: run time $runtime, under # $compiled" >&2
            exit 1
        fi
        if (( site_collections < 1 )); then
            echo "ct threads heap stress: build $round-$k: the site's runtime collected $site_collections times under stress" >&2
            exit 1
        fi
    done
done
echo "ct threads heap stress: 16 builds of a site starting 640 threads under stress, on two CPUs, all agree with run time ($compiler_collections collections of the compiler's heap in their windows)"
