#!/usr/bin/env bash
# A `#` site blocked in a system call (tests/cases/ct-time-limit: a read of a pipe nobody writes) ends the build with
# E_CT_TIME_LIMIT at ABLA_COMPILE_EVAL_TIME_LIMIT, under the interpreter as under the native tier: a build never hangs
# on compile-time code. The interpreter's alarm interrupts the call (EINTR) and the evaluator sees the deadline.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$project_root/build/ct-time-limit
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-time-limit"
for mode in interp jit; do
    status=0
    started=$SECONDS
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TIME_LIMIT=3 timeout 120 "$compiler" build blocked.ab -o "$out/$mode" \
        --fast --no-cache > "$out/$mode.log" 2>&1 || status=$?
    [[ $status == 1 ]] || { tail -5 "$out/$mode.log" >&2; echo "ct time limit: $mode: the compiler exited $status, not 1 (124: it hung)" >&2; exit 1; }
    grep -q '^error\[E_CT_TIME_LIMIT\]' "$out/$mode.log" ||
        { tail -5 "$out/$mode.log" >&2; echo "ct time limit: $mode: no E_CT_TIME_LIMIT" >&2; exit 1; }
    echo "ok   $mode: stopped after $((SECONDS - started)) s"
done
echo "ct time limit: a blocked compile-time site stops at the time limit in both tiers"
