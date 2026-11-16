#!/usr/bin/env bash
# #811: a fork by system call while another thread collects all the time. The forking thread is in native state during the
# call, so a collection can claim it and be in the middle of its stop at the instant of the fork; the child inherits the
# stop and the claim, and must not wait for a collector that did not survive. tests/cases/fork-stop/main.ab forks 200 times
# against a thread that allocates and collects without pause, each child exiting at once, and kills a child that is still
# there after five seconds. Before the fix 1 to 11 of the 200 children hung, in every one of 6 runs. Linux only (x86-64 and
# AArch64 under qemu).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'fork stop: Linux only'; exit 0; }
out="$root/build/fork-stop"
rm -rf "$out"
mkdir -p "$out"
fail() { echo "fork stop: $1" >&2; exit 1; }
"$compiler" build tests/cases/fork-stop/main.ab -o "$out/main" --fast --no-cache > "$out/build.log" 2>&1 \
    || { cat "$out/build.log" >&2; fail 'the program did not build'; }
for run in 1 2 3; do
    status=0
    ABLA_MAX_SECONDS=120 tools/run-limited.sh "$out/main" > "$out/run-$run.out" 2>&1 || status=$?
    [[ $status -eq 42 ]] || { cat "$out/run-$run.out" >&2; fail "run $run: status $status (a forked child hung during a stop?)"; }
done
echo "fork stop: 600 forks by system call during collections, no child hung"
