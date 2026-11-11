#!/usr/bin/env bash
set -euo pipefail
# `x ?? continue`, `?? break` and `?? break@label` as an assigned value leave the loop in the
# compile-time evaluator as they do in native code (the evaluator once stored the jump marker
# into the assigned variable: E_COMPILE_RESULT_NOT_LIFTABLE). The program runs one function
# natively and under `#` and compares the two texts.
compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$project_root/build/ct-elvis-jump"
fixture="$project_root/tests/cases/ct-elvis-jump/main.ab"
rm -rf "$out"
mkdir -p "$out"

for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build "$fixture" -o "$out/main-$mode" --fast --no-cache
    set +e
    text=$("$out/main-$mode")
    status=$?
    set -e
    [[ $status -eq 42 ]] || { echo "ct-elvis-jump ($mode): exit $status: $text" >&2; exit 1; }
    ABLA_COMPILE_EVAL=$mode "$compiler" build "$project_root/tests/cases/ct-elvis-jump/compiler.ab" -o "$out/compiler-$mode" --fast --no-cache
    set +e
    "$out/compiler-$mode"
    compiler_status=$?
    set -e
    [[ $compiler_status -eq 42 ]] || { echo "ct-elvis-jump compiler operands ($mode): exit $compiler_status" >&2; exit 1; }
    [[ $text == *" | "* ]] || { echo "ct-elvis-jump ($mode): unexpected output: $text" >&2; exit 1; }
done
# An escaped intrinsic must close its journal frame before the next call.
ABLA_ACTION_JOURNAL=1 ABLA_COMPILE_EVAL=interp "$compiler" build "$project_root/tests/cases/ct-elvis-jump/compiler.ab" -o "$out/journal" --fast --no-cache 2> "$out/journal.log"
awk '/^ACTION-JOURNAL call loop / { found = ($0 ~ /calls=5 replayable=false value of kind continue/); active = 1; next } /^ACTION-JOURNAL / { active = 0 } active && /compilerIsPrivate\|\?continue=\?continue/ { escaped = 1; next } active && escaped && /compilerFindFunction\|/ { later = 1 } END { exit !(found && escaped && later) }' "$out/journal.log" || { cat "$out/journal.log" >&2; echo "ct-elvis-jump: journal lost the escaped call or the following call" >&2; exit 1; }
echo "a jump on the right of ?? leaves its loop under # as in native code: $text"
