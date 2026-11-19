#!/usr/bin/env bash
# `time.unlimited` (decision #81 C, tests/cases/ct-time-unlimited): a module that requests it, with the manifest's
# authorization, runs its `#` sites without ABLA_COMPILE_EVAL_TIME_LIMIT; every other module's sites keep the limit,
# and a request the manifest doesn't authorize is refused like any capability's. A 1 s limit and sites that keep busy
# for 2.5 s, reading the clock, in both tiers.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$project_root/build/ct-time-unlimited
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-time-unlimited"
fail() { tail -5 "$1" >&2; echo "ct time unlimited: $2" >&2; exit 1; }
build() { # mode name file
    local status=0
    ABLA_COMPILE_EVAL=$1 ABLA_COMPILE_EVAL_TIME_LIMIT=1 ABLA_COMPILE_EVAL_TRACE=1 timeout 120 "$compiler" build "$3" -o "$out/$2-$1" \
        --fast --no-cache > "$out/$2-$1.log" 2>&1 || status=$?
    echo "$status"
}
for mode in interp jit; do for name in slow granting; do
    status=$(build $mode $name $name.ab)
    [[ $status == 1 ]] || fail "$out/$name-$mode.log" "$mode: $name.ab: the compiler exited $status, not 1"
    grep -q '^error\[E_CT_TIME_LIMIT\]' "$out/$name-$mode.log" || fail "$out/$name-$mode.log" "$mode: $name.ab: no E_CT_TIME_LIMIT"
done; done
echo "ok   the limit stops slow.ab, and the imported module of granting.ab, which requests time.unlimited itself"
for mode in interp jit; do
    status=$(build $mode unlimited unlimited.ab)
    [[ $status == 0 ]] || fail "$out/unlimited-$mode.log" "$mode: unlimited.ab: the compiler exited $status"
    run=0; "$out/unlimited-$mode" || run=$?
    [[ $run == 42 ]] || { echo "ct time unlimited: $mode: unlimited.ab's program exited $run, not 42" >&2; exit 1; }
    echo "ok   $mode: unlimited.ab's site runs past the limit"
done
# In one native call: shared/played.ab's slow site is kept by the slice, and quick.ab's call (the generation's
# first) runs it while it initializes the globals the slice keeps. Only that site's code is unlimited: the call runs
# past the limit for it, and a call whose own code is slow (slow-first.ab's) still stops.
status=$(build jit shared shared/played.ab)
[[ $status == 0 ]] || fail "$out/shared-jit.log" "shared: played.ab: the compiler exited $status"
run=0; "$out/shared-jit" || run=$?
[[ $run == 42 ]] || { echo "ct time unlimited: shared: played.ab's program exited $run, not 42" >&2; exit 1; }
# Natively: the pass has its generation (the pause is the slice's own code, which needs no grant), and quick.ab's site
# runs there. In the evaluator a pass would pass this case without any pause.
grep -q '^note\[ct-jit\]: native at .*quick.ab:' "$out/shared-jit.log" && ! grep -q 'interpreted at' "$out/shared-jit.log" ||
    fail "$out/shared-jit.log" "shared: played.ab's pass didn't run natively"
status=$(build jit shared-slow shared/played-slow-first.ab)
[[ $status == 1 ]] || fail "$out/shared-slow-jit.log" "shared: played-slow-first.ab: the compiler exited $status, not 1"
grep -q '^error\[E_CT_TIME_LIMIT\]' "$out/shared-slow-jit.log" ||
    fail "$out/shared-slow-jit.log" "shared: played-slow-first.ab: no E_CT_TIME_LIMIT"
echo "ok   jit: an unlimited site kept by the slice runs past the limit in another site's call, whose own code doesn't"
status=$(build interp unauthorized unauthorized/main.ab)
[[ $status == 1 ]] || fail "$out/unauthorized-interp.log" "unauthorized: the compiler exited $status, not 1"
grep -q 'compile.capability-not-authorized:time.unlimited' "$out/unauthorized-interp.log" ||
    fail "$out/unauthorized-interp.log" "unauthorized: no compile.capability-not-authorized:time.unlimited"
echo "ok   a request the manifest doesn't authorize is refused"
echo "ct time unlimited: only a module that requests time.unlimited, authorized, runs without the time limit"
