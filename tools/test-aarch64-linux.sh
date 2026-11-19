#!/usr/bin/env bash
# #811: `--target aarch64-linux` builds a static executable that needs no libc and no
# dynamic loader, and the small hosted programs and the system call checks behave under
# qemu-aarch64 exactly as the x86-64 builds do (output and exit status).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
if [[ $(uname -s) != Linux ]]; then echo 'aarch64 linux: Linux only'; exit 0; fi
out="$root/build/aarch64-linux"
rm -rf "$out"
mkdir -p "$out"
fail() { echo "aarch64 linux: $1" >&2; exit 1; }
# The builds are independent: they run in workers, 2 at once under the suite (tools/run-tests.sh sets ABLA_SUITE_JOBS; the
# suite's other jobs are running too), else one per CPU this process may use (nproc follows taskset), at most 8.
# ABLA_TEST_JOBS overrides. Every worker's output goes to its own file under $out; the first failure is reported.
workers=${ABLA_TEST_JOBS:-}
if [[ -z $workers ]]; then
    if [[ -n ${ABLA_SUITE_JOBS:-} ]]; then workers=2; else workers=$(nproc 2> /dev/null || echo 2); ((workers <= 8)) || workers=8; fi
fi
[[ $workers =~ ^[1-9][0-9]*$ ]] || fail "ABLA_TEST_JOBS must be a positive integer, got $workers"
failed_jobs=()
parallel_each() { # FUNCTION ARGUMENT...: FUNCTION ARGUMENT for each argument, $workers at once; fails when any fails
    local function_name=$1 argument pid
    shift
    local pids=() arguments=()
    for argument in "$@"; do
        while ((${#pids[@]} >= workers)); do
            wait_one
        done
        "$function_name" "$argument" > "$out/job-${argument//\//_}-$function_name.log" 2>&1 &
        pids+=($!)
        arguments+=("$argument")
    done
    while ((${#pids[@]} > 0)); do wait_one; done
    if ((${#failed_jobs[@]} > 0)); then
        for argument in "${failed_jobs[@]}"; do cat "$out/job-${argument//\//_}-$function_name.log" >&2; done
        exit 1
    fi
}
wait_one() { # waits for the oldest worker; records the argument of one that failed
    if ! wait "${pids[0]}"; then failed_jobs+=("${arguments[0]}"); fi
    pids=("${pids[@]:1}")
    arguments=("${arguments[@]:1}")
}
have_qemu=1
command -v qemu-aarch64 > /dev/null || have_qemu=0
programs='tests/cases/libc-imports/hello.ab tests/cases/libc-imports/float-remainder.ab
tests/cases/libc-imports/strings-arrays.ab tests/cases/libc-imports/files.ab
tests/cases/libc-imports/tasks.ab tests/cases/libc-imports/threads.ab'
checks='tests/cases/linux-syscall/main.ab tests/cases/linux-syscall/legacy.ab tests/cases/linux-syscall/epoll.ab
tests/cases/modules/http-client.ab
tests/cases/linux-syscall/random.ab tests/cases/linux-syscall/wide.ab tests/cases/linux-syscall/int128.ab tests/cases/linux-syscall/memory.ab
tests/cases/libc-memory-routines/main.ab tests/cases/rsa-default-random/main.ab'
program_check() { # SOURCE: both modes, built for AArch64, checked, and run under qemu against the native build
    local source=$1 name mode flags file_kind native_status foreign_status
    name=$(basename "$source" .ab)-$(basename "$(dirname "$source")")
    for mode in release fast; do
        flags=''
        [[ $mode == release ]] || flags=--fast
        # shellcheck disable=SC2086
        "$compiler" build "$source" --target aarch64-linux -o "$out/$name-$mode" --no-cache $flags \
            > "$out/$name-$mode.log" 2>&1 || { cat "$out/$name-$mode.log" >&2; fail "$name $mode did not build"; }
        file_kind=$(readelf -h "$out/$name-$mode" | awk '/Machine:/ { print $2 }')
        [[ $file_kind == AArch64 ]] || fail "$name $mode is not an AArch64 executable ($file_kind)"
        if readelf -d "$out/$name-$mode" 2> /dev/null | grep NEEDED >/dev/null || readelf -l "$out/$name-$mode" | grep INTERP >/dev/null; then
            fail "$name $mode needs a shared library or a loader"
        fi
        [[ $have_qemu -eq 1 ]] || continue
        native_status=0
        foreign_status=0
        # shellcheck disable=SC2086
        "$compiler" build "$source" -o "$out/$name-native-$mode" --no-cache $flags > /dev/null 2>&1 \
            || fail "$name $mode native build failed"
        (cd "$out" && timeout 120 "./$name-native-$mode" < /dev/null > "$name-$mode.native.out" 2> /dev/null) || native_status=$?
        (cd "$out" && timeout 300 qemu-aarch64 "./$name-$mode" < /dev/null > "$name-$mode.out" 2> /dev/null) || foreign_status=$?
        [[ $native_status -eq $foreign_status ]] || fail "$name $mode: status $foreign_status under qemu, $native_status natively"
        cmp -s "$out/$name-$mode.native.out" "$out/$name-$mode.out" || fail "$name $mode: output differs from the native build"
    done
}
# shellcheck disable=SC2086
parallel_each program_check $programs $checks
# Static and libc-free, built only (no run): the other libc-imports programs that have an AArch64 build (tls-http needs
# OpenSSL, which has none) in both modes, and one program for each stdlib area a libc-free build can still reach libc
# from (sockets, processes, signals, stm, tls/pure, http/async, websocket), --fast. A regression there would otherwise
# show only on a machine that runs AArch64.
static_both='tests/cases/libc-imports/http-async-tls.ab tests/cases/libc-imports/jwt-verify.ab
tests/cases/libc-imports/tls-pure-https.ab tests/cases/libc-imports/tls-pure-thread.ab
tests/cases/libc-imports/websocket-server-tls.ab'
static_fast='tests/cases/modules/hosted-network.ab tests/cases/modules/udp-ephemeral.ab tests/cases/modules/linux-process.ab
tests/cases/modules/process-capture.ab tests/cases/modules/signal-watch.ab tests/cases/stm/bank.ab
tests/cases/tls-pure/client.ab tests/cases/modules/http-async.ab tests/cases/modules/websocket-event.ab
tests/cases/modules/websocket-server.ab'
static_check() { # SOURCE MODE: builds for AArch64 and requires no library, loader or undefined symbol
    local source=$1 mode=$2 name flags=''
    name=static-$(basename "$source" .ab)-$mode
    [[ $mode == release ]] || flags=--fast
    # shellcheck disable=SC2086
    "$compiler" build "$source" --target aarch64-linux -o "$out/$name" --no-cache $flags \
        > "$out/$name.log" 2>&1 || { cat "$out/$name.log" >&2; fail "$source ($mode) did not build"; }
    if readelf -d "$out/$name" 2> /dev/null | grep NEEDED >/dev/null || readelf -l "$out/$name" | grep INTERP >/dev/null ||
        [[ -n $(nm -D --undefined-only "$out/$name" 2> /dev/null) ]]; then
        fail "$source ($mode) links libc or leaves a symbol undefined"
    fi
}
static_both_check() { static_check "$1" release; static_check "$1" fast; }
static_fast_check() { static_check "$1" fast; }
# The release builds of these were 45 of this test's 120 CPU-seconds (about 9 each). The suite builds one of them for
# release, http-async-tls (tls/pure, http/async and the event loop: the widest reach), and the rest at --fast;
# RUN_TESTS_FULL=1 (or AARCH64_RELEASE_ALL=1) builds all of them both ways.
if [[ -z ${AARCH64_RELEASE_ALL:-${RUN_TESTS_FULL:-}} ]]; then
    static_both_release='tests/cases/libc-imports/http-async-tls.ab'
    static_fast="$static_fast ${static_both//tests\/cases\/libc-imports\/http-async-tls.ab/}"
    static_both=$static_both_release
fi
# shellcheck disable=SC2086
parallel_each static_both_check $static_both
# shellcheck disable=SC2086
parallel_each static_fast_check $static_fast
if [[ $have_qemu -eq 1 ]]; then
    # A bad access in a --fast build: the fault report, then the default action (SIGSEGV).
    # The debug runtime needs debug information, which the suite turns off (ABLA_DEBUG=0).
    ABLA_DEBUG=1 "$compiler" build tests/cases/linux-syscall/fault.ab --target aarch64-linux -o "$out/fault" --fast --no-cache > /dev/null 2>&1 || fail "the fault program did not build"
    status=0
    (ulimit -c 0; timeout 300 qemu-aarch64 "$out/fault" < /dev/null > /dev/null 2> "$out/fault.err") || status=$?
    [[ $status -eq 139 ]] && grep -q "^fatal signal" "$out/fault.err" && grep -q "^0x" "$out/fault.err" || fail "fault report: status $status, $(cat "$out/fault.err")"
    for mode in "" --fast; do
        # shellcheck disable=SC2086
        "$compiler" build tests/cases/linux-syscall/stack-overflow.ab --target aarch64-linux -o "$out/overflow" --no-cache $mode > /dev/null 2>&1 || fail "the stack overflow program did not build"
        status=0
        timeout 300 qemu-aarch64 "$out/overflow" < /dev/null > /dev/null 2> "$out/overflow.err" || status=$?
        [[ $status -eq 101 ]] && grep -qx "panic: stack overflow" "$out/overflow.err" || fail "stack overflow: status $status, $(cat "$out/overflow.err")"
        # shellcheck disable=SC2086
        "$compiler" build tests/cases/linux-syscall/thread-stack-overflow.ab --target aarch64-linux -o "$out/thread-overflow" --no-cache $mode > /dev/null 2>&1 || fail "the thread stack overflow program did not build"
        status=0
        timeout 300 qemu-aarch64 "$out/thread-overflow" < /dev/null > /dev/null 2> "$out/thread-overflow.err" || status=$?
        [[ $status -eq 101 ]] && grep -qx "panic: stack overflow" "$out/thread-overflow.err" || fail "a thread's stack overflow: status $status, $(cat "$out/thread-overflow.err")"
    done
    echo 'aarch64 linux: static libc-free builds run under qemu-aarch64 like the x86-64 ones'
else
    echo 'aarch64 linux: static libc-free builds made; no qemu-aarch64, not run'
fi
