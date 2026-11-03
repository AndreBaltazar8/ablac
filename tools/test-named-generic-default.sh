#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/named-generic-default-test
mkdir -p "$out"
for case in main foreign borrowed extension multiple-receivers interface nested modules type-in-default delegated-valid resource-default; do
    "$compiler" build "tests/cases/named-generic-default/$case.ab" -o "$out/$case" --fast --no-cache
    "$out/$case"
done
for mode in interp jit; do
    ABLA_COMPILE_EVAL="$mode" ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build \
        tests/cases/named-generic-default/staged.ab -o "$out/staged" --fast --no-cache 2>"$out/$mode.trace"
    "$out/staged"
done
grep -q 'native at' "$out/jit.trace"
for spec in 'required:generic.cannot-infer:f:T' 'required-expression:generic.cannot-infer:f:T' 'own-invalid:ownership.move-required' 'delegated:E_NAMED_ARGUMENT_HIDDEN'; do
    case=${spec%%:*}
    error=${spec#*:}
    if "$compiler" build "tests/cases/named-generic-default/$case.ab" -o "$out/$case" --fast --no-cache >"$out/$case.log" 2>&1; then
        echo "$case unexpectedly compiled" >&2; exit 1
    fi
    grep -Fq "$error" "$out/$case.log" || { cat "$out/$case.log" >&2; exit 1; }
done
"$compiler" build tests/cases/named-generic-default/build-wasm.ab -o "$out/wasm-driver" --no-cache
"$out/wasm-driver"
node tests/cases/named-generic-default/run.mjs "$out/main.wasm"
echo 'generic named defaults keep callee scope, infer types and preserve ownership and order'
