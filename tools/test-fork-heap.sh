#!/usr/bin/env bash
# #812: a fork while another thread holds the runtime's heap lock must not leave the child's heap locked for ever.
# A thread allocates and frees all the time while the process forks 300 times, and each child allocates and checks
# what it built (a hang is the old failure: every child and the whole run are bounded by a time limit):
#   - an Abla program on x86-64 with its own libc fork, release and --fast;
#   - the same with the fork system call (what an AArch64 Linux program has), x86-64 and, under qemu-aarch64,
#     AArch64;
#   - a shared library whose C host forks while one of the host's threads allocates in the library (x86-64).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'fork heap: Linux only'; exit 0; }
out="$root/build/fork-heap"
rm -rf "$out"
mkdir -p "$out"
fail() { echo "fork heap: $1" >&2; exit 1; }
# A run that reaches the 120 s limit has hung somewhere (it takes about half a second, and 380 runs on a machine
# loaded with 40 busy loops never came near): at 100 s a watchdog writes what every process of the run, and every
# thread of each, is doing (state and kernel wait channel), so the failure says whether the parent, a child or
# one of the churning threads is stuck and on what, instead of only that the limit passed.
hang_report() { # file, run-limited's pid
    sleep 100 &
    local nap=$!
    trap 'kill "$nap" 2> /dev/null; exit 0' TERM
    wait "$nap"
    {
        echo "state of the run at 100 s (pid state wchan comm):"
        local pid task
        for pid in "$2" $(pgrep -P "$2" 2> /dev/null) $(pgrep -f "$out" 2> /dev/null); do
            [[ -d /proc/$pid ]] || continue
            for task in /proc/$pid/task/*; do
                echo "  ${task#/proc/} $(awk '/^State:/ {print $2}' "$task/status" 2> /dev/null) $(cat "$task/wchan" 2> /dev/null) $(cat "$task/comm" 2> /dev/null)"
            done
        done
    } > "$1" 2>&1
}
run() { # label, then the command
    local label=$1 result report="$out/hang-report.txt" runner watchdog status=0
    shift
    : > "$report"
    ABLA_MAX_SECONDS=120 "$root/tools/run-limited.sh" "$@" > "$out/run.out" 2>&1 &
    runner=$!
    hang_report "$report" "$runner" &
    watchdog=$!
    wait "$runner" || status=$?
    kill "$watchdog" 2> /dev/null || true
    wait "$watchdog" 2> /dev/null || true
    result=$(cat "$out/run.out")
    [[ $status -eq 0 ]] || fail "$label: $result$([[ -s $report ]] && printf '\n%s' "$(cat "$report")")"
    [[ $result == *"failures 0"* || $result == *'fork heap library ok'* ]] || fail "$label said: $result"
}
x86=0
[[ $(uname -m) == x86_64 ]] && x86=1
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    if [[ $x86 == 1 ]]; then
        "$compiler" build tests/cases/fork-heap/main.ab -o "$out/libc-$mode" "${flags[@]}"
        run "libc fork ($mode)" "$out/libc-$mode"
        # The same program with background freeing on (memorySetBackgroundFree): its collector once lacked the fork child's first-call repair, so the
        # child's first collection waited out the 20 ms of a stop for the parent's threads that are gone, 300 times (6 s, not 0.15 s), and said
        # "stop abandoned" each time (25 to 300 of them in a run; a stop is abandoned now and then on a loaded machine, a thread that was not
        # scheduled looks like one that never parks, so up to a tenth of the 300 forks (30) are allowed: the unrepaired runtime abandoned 99-300 locally, the repaired one 0-2, and 10 failed on a loaded 4-core CI runner).
        sed 's/^trusted fun main: int {$/&\n    memorySetBackgroundFree(true)/' tests/cases/fork-heap/main.ab > "$out/background.ab"
        "$compiler" build "$out/background.ab" -o "$out/background-$mode" "${flags[@]}"
        ABLA_GC_TRACE=1 run "libc fork with background freeing ($mode)" "$out/background-$mode"
        abandoned=$(grep -ac 'stop abandoned' "$out/run.out" || true)
        ((abandoned < 30)) || fail "libc fork with background freeing ($mode): $abandoned collection stops were abandoned (a forked child waited for threads that are gone)"
        "$compiler" build tests/cases/fork-heap/syscall.ab -o "$out/syscall-$mode" "${flags[@]}"
        run "fork system call ($mode)" "$out/syscall-$mode"
    fi
    if command -v qemu-aarch64 > /dev/null; then
        "$compiler" build tests/cases/fork-heap/syscall.ab --target aarch64-linux -o "$out/arm-$mode" "${flags[@]}"
        run "fork system call, AArch64 ($mode)" qemu-aarch64 "$out/arm-$mode"
    fi
done
host_cc=${CC:-}
[[ -n $host_cc ]] || { command -v clang > /dev/null && host_cc=clang || host_cc=cc; }
if [[ $x86 == 1 ]] && command -v "$host_cc" > /dev/null; then
    "$host_cc" tests/cases/fork-heap-library/host.c -o "$out/host" -ldl -lpthread
    for mode in release fast; do
        flags=(--no-cache)
        [[ $mode == fast ]] && flags+=(--fast)
        "$compiler" build tests/cases/fork-heap-library/lib.ab --emit shared-library -o "$out/lib-$mode.so" "${flags[@]}"
        run "C host forking ($mode)" "$out/host" "$out/lib-$mode.so"
    done
else
    echo 'fork heap: no x86-64 host or C compiler; the library case is skipped'
fi
echo 'fork heap ok'
