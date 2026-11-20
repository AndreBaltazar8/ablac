#!/usr/bin/env bash
# What auto's fallback to the evaluator costs is shown (tests/cases/ct-fallback): slow.ab's site, which the native
# tier doesn't take, keeps the evaluator busy for over a second. Under auto the build notes it without the trace
# (where, how long, why); under interp, which asks for the evaluator, it doesn't; and the trace's fallback note
# carries the time.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$project_root/build/ct-fallback
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-fallback"
fail() { echo "ct fallback: $1" >&2; [[ -z ${2:-} ]] || tail -8 "$2" >&2; exit 1; }
build() { # tier trace(0/1) log
    local status=0
    ABLA_COMPILE_EVAL=$1 ABLA_COMPILE_EVAL_TRACE=$2 timeout 300 "$compiler" build slow.ab -o "$out/$3" --fast \
        --no-cache > "$out/$3.log" 2>&1 || status=$?
    [[ $status == 0 ]] || fail "$3: the compiler exited $status" "$out/$3.log"
    status=0; "$out/$3" || status=$?
    [[ $status == 42 ]] || fail "$3: the program exited $status, not 42" "$out/$3.log"
}
build auto 0 auto
grep -q '^note: the `#` site at slow.ab:[0-9]*:[0-9]* ran in the compile-time evaluator for [0-9]*\.[0-9] s, not as native code: reaches extern:"compiler" fun compilerApplyTransform' \
    "$out/auto.log" || fail "no note under auto" "$out/auto.log"
build interp 0 interp
! grep -q 'ran in the compile-time evaluator' "$out/interp.log" || fail "a note under interp" "$out/interp.log"
build auto 1 traced
grep -q '^note\[ct-jit\]: interpreted at [0-9]*: .*compilerApplyTransform.* ([0-9]* ms)$' "$out/traced.log" ||
    fail "the trace's note has no time" "$out/traced.log"
echo "ct fallback: a slow fallback to the evaluator is noted under auto, with its place, time and reason"
