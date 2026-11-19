#!/usr/bin/env bash
# A `#` site that runs too long ends the build with E_CT_TIME_LIMIT at ABLA_COMPILE_EVAL_TIME_LIMIT, under the
# interpreter as under the native tier: a build never hangs on compile-time code (tests/cases/ct-time-limit).
# - blocked.ab: a read of a pipe nobody writes. The interpreter's alarm interrupts the call (EINTR) and the evaluator
#   sees the deadline.
# - sleeping.ab: a minute's sleep, which runs in the compiler (a provider). It wakes at the deadline: the interpreter
#   used to sleep the whole minute (#1037).
# - clocked.ab: a minute of clock reads, each a call into the compiler. The native tier's stop waits for the
#   compiler's code to return: it used to jump over it and take the compiler down (#1036).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$project_root/build/ct-time-limit
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-time-limit"
for case in blocked sleeping clocked; do
    for mode in interp jit; do
        status=0
        started=$SECONDS
        log=$out/$case-$mode.log
        ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TIME_LIMIT=3 timeout 120 "$compiler" build $case.ab -o "$out/$case-$mode" \
            --fast --no-cache > "$log" 2>&1 || status=$?
        spent=$((SECONDS - started))
        [[ $status == 1 ]] || { tail -5 "$log" >&2; echo "ct time limit: $case $mode: the compiler exited $status, not 1 (124: it hung; 139: it crashed)" >&2; exit 1; }
        grep -q '^error\[E_CT_TIME_LIMIT\]' "$log" ||
            { tail -5 "$log" >&2; echo "ct time limit: $case $mode: no E_CT_TIME_LIMIT" >&2; exit 1; }
        (( spent < 40 )) || { echo "ct time limit: $case $mode: stopped only after $spent s" >&2; exit 1; }
        echo "ok   $case $mode: stopped after $spent s"
    done
done
echo "ct time limit: a blocked, sleeping or clock-reading compile-time site stops at the time limit in both tiers"
