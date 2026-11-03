#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/named-affine-borrow-test
mkdir -p "$out"
for case in main order member; do
    "$compiler" build "tests/cases/named-affine-borrow/$case.ab" -o "$out/$case" --fast --no-cache
    "$out/$case"
done
for mode in interp jit; do
    ABLA_COMPILE_EVAL="$mode" ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build \
        tests/cases/named-affine-borrow/staged.ab -o "$out/staged" --fast --no-cache 2>"$out/$mode.log"
    "$out/staged"
done
grep -q 'native at' "$out/jit.log"
for case in conflict evaluation-conflict; do
    if "$compiler" build "tests/cases/named-affine-borrow/$case.ab" -o "$out/$case" --fast --no-cache >"$out/$case.log" 2>&1; then
        echo "$case unexpectedly compiled" >&2; exit 1
    fi
    grep -q 'E_BORROW_CONFLICT' "$out/$case.log" || { cat "$out/$case.log" >&2; exit 1; }
done
if "$compiler" build tests/cases/named-affine-borrow/own-invalid.ab -o "$out/own-invalid" --fast --no-cache >"$out/own-invalid.log" 2>&1; then
    echo 'own-invalid unexpectedly compiled' >&2; exit 1
fi
grep -q 'ownership.move-required' "$out/own-invalid.log"
echo 'named calls borrow affine arguments at their original evaluation point'
