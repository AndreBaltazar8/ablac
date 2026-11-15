#!/usr/bin/env bash
# A native compile-time stop beside running threads (#831). A `#` site that panics while a thread it started still
# runs used to leave the compiler going on beside that thread, which crashed it at random (SIGILL, SIGSEGV: its
# collector roots and heap were used from both sides). The build must end with E_CT_STOPPED naming the stop, every
# time and never by a signal. A thread that panics jumped back to the compiler's stack from its own thread; it now
# parks and the site's thread stops, with the same E_CT_STOPPED. A site that awaited its thread still reports its
# panic (E_CT_PANIC). A thread whose stack overflows (it has a signal stack of its own) stops the same way.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases=$project_root/tests/cases/ct-stop-threads
output_directory="$project_root/build/ct-stop-threads"
rm -rf "$output_directory"
mkdir -p "$output_directory"
fail() { echo "ct stop threads: $1" >&2; [[ -z ${2:-} ]] || cat "$2" >&2; exit 1; }

runs=${CT_STOP_THREADS_RUNS:-6}
for run in $(seq 1 "$runs"); do
    log=$output_directory/orphan-$run.log
    status=0
    ABLA_COMPILE_EVAL=jit "$compiler" build "$cases/orphan.ab" -o "$output_directory/orphan" --no-cache \
        > "$log" 2>&1 || status=$?
    [[ $status == 1 ]] || fail "orphan run $run: the compiler exited $status, not 1" "$log"
    grep -q '^error\[E_CT_STOPPED\]: compile-time evaluation at .* panicked: stopped while a thread runs, while [0-9]* thread(s) it started still run' "$log" ||
        fail "orphan run $run: no E_CT_STOPPED naming the panic and the running thread" "$log"
done

for run in $(seq 1 "$runs"); do
    log=$output_directory/thread-panic-$run.log
    status=0
    ABLA_COMPILE_EVAL=jit "$compiler" build "$cases/thread-panic.ab" -o "$output_directory/thread-panic" --no-cache \
        > "$log" 2>&1 || status=$?
    [[ $status == 1 ]] || fail "thread-panic run $run: the compiler exited $status, not 1" "$log"
    grep -q '^error\[E_CT_STOPPED\]: compile-time evaluation at .* panicked: a thread gave up, while 1 thread(s) it started still run' "$log" ||
        fail "thread-panic run $run: no E_CT_STOPPED naming the thread's panic" "$log"
done

for run in $(seq 1 "$runs"); do
    log=$output_directory/thread-overflow-$run.log
    status=0
    ABLA_COMPILE_EVAL=jit "$compiler" build "$cases/thread-overflow.ab" -o "$output_directory/thread-overflow" --no-cache \
        > "$log" 2>&1 || status=$?
    [[ $status == 1 ]] || fail "thread-overflow run $run: the compiler exited $status, not 1" "$log"
    grep -q '^error\[E_CT_STOPPED\]: compile-time evaluation at .* made a bad memory access, while 1 thread(s) it started still run' "$log" ||
        fail "thread-overflow run $run: no E_CT_STOPPED for the thread's stack overflow" "$log"
done

log=$output_directory/awaited.log
status=0
ABLA_COMPILE_EVAL=jit "$compiler" build "$cases/awaited.ab" -o "$output_directory/awaited" --no-cache \
    > "$log" 2>&1 || status=$?
[[ $status == 1 ]] || fail "awaited: the compiler exited $status, not 1" "$log"
grep -q '^error\[E_CT_PANIC\]: stopped after its thread' "$log" || fail "awaited: the panic was not reported" "$log"
! grep -q 'still run' "$log" || fail "awaited: reported running threads that had ended" "$log"
echo "ct stop threads: a stop beside running threads ends the build with E_CT_STOPPED ($runs runs); an awaited one reports its panic"
