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
    [[ $text == *" | "* ]] || { echo "ct-elvis-jump ($mode): unexpected output: $text" >&2; exit 1; }
done
echo "a jump on the right of ?? leaves its loop under # as in native code: $text"
