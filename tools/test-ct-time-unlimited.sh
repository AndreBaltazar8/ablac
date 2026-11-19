#!/usr/bin/env bash
# `time.unlimited` (decision #81 C, tests/cases/ct-time-unlimited): a module that requests it, with the manifest's
# authorization, runs its `#` sites without ABLA_COMPILE_EVAL_TIME_LIMIT; every other module's sites keep the limit,
# and a request the manifest doesn't authorize is refused like any capability's. A 1 s limit and sites that keep busy
# for 2.5 s, reading the clock. The unlimited site runs in both tiers; the stopped ones in the interpreter, since a
# native site stopped inside a clock call takes the compiler down (#1036).
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
    ABLA_COMPILE_EVAL=$1 ABLA_COMPILE_EVAL_TIME_LIMIT=1 timeout 120 "$compiler" build "$3" -o "$out/$2-$1" \
        --fast --no-cache > "$out/$2-$1.log" 2>&1 || status=$?
    echo "$status"
}
for name in slow granting; do
    status=$(build interp $name $name.ab)
    [[ $status == 1 ]] || fail "$out/$name-interp.log" "$name.ab: the compiler exited $status, not 1"
    grep -q '^error\[E_CT_TIME_LIMIT\]' "$out/$name-interp.log" || fail "$out/$name-interp.log" "$name.ab: no E_CT_TIME_LIMIT"
done
echo "ok   the limit stops slow.ab, and the imported module of granting.ab, which requests time.unlimited itself"
for mode in interp jit; do
    status=$(build $mode unlimited unlimited.ab)
    [[ $status == 0 ]] || fail "$out/unlimited-$mode.log" "$mode: unlimited.ab: the compiler exited $status"
    run=0; "$out/unlimited-$mode" || run=$?
    [[ $run == 42 ]] || { echo "ct time unlimited: $mode: unlimited.ab's program exited $run, not 42" >&2; exit 1; }
    echo "ok   $mode: unlimited.ab's site runs past the limit"
done
status=$(build interp unauthorized unauthorized/main.ab)
[[ $status == 1 ]] || fail "$out/unauthorized-interp.log" "unauthorized: the compiler exited $status, not 1"
grep -q 'compile.capability-not-authorized:time.unlimited' "$out/unauthorized-interp.log" ||
    fail "$out/unauthorized-interp.log" "unauthorized: no compile.capability-not-authorized:time.unlimited"
echo "ok   a request the manifest doesn't authorize is refused"
echo "ct time unlimited: only a module that requests time.unlimited, authorized, runs without the time limit"
