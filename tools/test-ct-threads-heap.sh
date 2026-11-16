#!/usr/bin/env bash
# A native `#` site that starts many threads at once, round after round (tests/cases/ct-threads-heap): the compiler's
# heap, which their emulated thread-locals come from, must be shared before they start, or the build stops at random
# (E_CT_STOPPED in the root-frame unlink, or a bad access). Several builds at once on two CPUs, as a loaded gate runs
# them; every one must finish and agree with run time.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
out="$project_root/build/ct-threads-heap"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-threads-heap"
cpus=$(nproc)
pin=()
if command -v taskset >/dev/null && (( cpus > 2 )); then pin=(taskset -c 0,1); fi
for round in 1 2 3 4; do
    pids=()
    for k in 1 2 3 4 5 6 7 8; do
        ( ABLA_COMPILE_EVAL=jit "${pin[@]}" "$compiler" build main.ab -o "$out/p-$round-$k" --fast --no-cache \
            > "$out/b-$round-$k.log" 2>&1 ) & pids+=($!)
    done
    for k in 1 2 3 4 5 6 7 8; do
        wait "${pids[$((k - 1))]}" || { cat "$out/b-$round-$k.log" >&2; echo "ct threads heap: build $round-$k failed" >&2; exit 1; }
    done
done
read -r runtime compiled < <("$out/p-1-1")
[[ $runtime == "$compiled" && $runtime -gt 0 ]] || { echo "ct threads heap: run time $runtime, under # $compiled" >&2; exit 1; }
echo "ct threads heap: 32 builds of a site starting 640 threads in rounds of 8, on two CPUs, all agree with run time"
