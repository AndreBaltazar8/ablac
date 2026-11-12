#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/compile-global-graph
mkdir -p "$out"
ABLA_COMPILE_EVAL=interp "$compiler" build tests/cases/compile-global-graph/main.ab \
    -o "$out/main" --fast --no-cache >"$out/main.log" 2>&1
actual=$("$out/main")
expected='1,2,3|1,2,3|2,4,6|1,2,3|2,4,6'
[[ $actual == "$expected"$'\n'"$expected" ]] || { printf 'global graph mismatch: %s\n' "$actual" >&2; exit 1; }
ABLA_COMPILE_EVAL=interp "$compiler" build tests/cases/compile-global-graph/captured.ab \
    -o "$out/captured" --fast --no-cache >"$out/captured.log" 2>&1
actual=$("$out/captured")
[[ $actual == $'1,2,3\n1,2,3' ]] || { printf 'compile/ordinary alias mismatch: %s\n' "$actual" >&2; exit 1; }
ABLA_COMPILE_EVAL=interp "$compiler" build tests/cases/compile-global-graph/closure-edit.ab \
    -o "$out/closure-edit" --fast --no-cache >"$out/closure-edit.log" 2>&1
actual=$("$out/closure-edit")
[[ $actual == '11,11,11,11,12,12,12' ]] || { printf 'closure version mismatch: %s\n' "$actual" >&2; exit 1; }
for refusal in refused-closure-edit refused-same-lambda; do
    if ABLA_COMPILE_EVAL=interp "$compiler" build "tests/cases/compile-global-graph/$refusal.ab" \
        -o "$out/$refusal" --fast --no-cache >"$out/$refusal.log" 2>&1; then
        echo "$refusal unexpectedly lifted" >&2; exit 1
    fi
    grep -Fq 'this kept closure predates a later compile-time transform; its original captured layout is no longer known' "$out/$refusal.log"
done
# A native closure kept across a compile-time edit would run the edited body (#796): a pass that
# changes declarations interprets the sites that make closures.
for mode in interp jit auto; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build tests/cases/compile-global-graph/round-retry.ab \
        -o "$out/round-retry-$mode" --fast --no-cache >"$out/round-retry-$mode.log" 2>&1
    actual=$("$out/round-retry-$mode")
    [[ $actual == '11,12' ]] || { printf 'graph retry mismatch (%s): %s\n' "$mode" "$actual" >&2; exit 1; }
done
if ABLA_COMPILE_EVAL=interp ABLA_EVAL_STEP_LIMIT=200 "$compiler" build \
    tests/cases/compile-global-graph/stopped-mutation.ab -o "$out/stopped" --fast --no-cache \
    >"$out/stopped.log" 2>&1; then
    echo 'expected the mutation evaluation to stop' >&2; exit 1
fi
grep -Fq 'E_EVAL_STEP_LIMIT' "$out/stopped.log"
[[ $(grep -c '^error\[' "$out/stopped.log") == 1 ]] || { cat "$out/stopped.log" >&2; exit 1; }
"$compiler" build tests/cases/compile-global-graph/codec.ab \
    -o "$out/codec" --fast --no-cache >"$out/codec.log" 2>&1
"$out/codec"
echo 'compile-time global graph: cross-root aliases, nested/map/cycle and compile/ordinary identity; frozen closure versions passed'
