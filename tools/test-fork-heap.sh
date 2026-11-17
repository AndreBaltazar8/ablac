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
run() { # label, then the command
    local label=$1 result
    shift
    result=$(ABLA_MAX_SECONDS=120 "$root/tools/run-limited.sh" "$@" 2>&1) || fail "$label: $result"
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
