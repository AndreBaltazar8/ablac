#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/lazy-defaults-test
mkdir -p "$out"
for mode in --fast --o1; do
    "$compiler" build tests/cases/lazy-defaults/main.ab -o "$out/main" "$mode" --no-cache
    "$out/main"
done
for mode in interp jit; do
    ABLA_COMPILE_EVAL="$mode" ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build \
        tests/cases/lazy-defaults/staged.ab -o "$out/staged" --fast --no-cache 2>"$out/$mode.trace"
    "$out/staged"
done
grep -q 'native at' "$out/jit.trace"
# In release output, a pure default needed by no caller is eliminated. The
# omitted-argument control proves the sentinel is observable when needed.
sed 's/identity("ok")/identity()/' tests/cases/lazy-defaults/pure.ab > "$out/needed.ab"
"$compiler" build tests/cases/lazy-defaults/pure.ab -o "$out/supplied" --no-cache
"$compiler" build "$out/needed.ab" -o "$out/needed" --no-cache
[[ $("$out/supplied") == ok ]]
[[ $("$out/needed") == ABLA_UNUSED_DEFAULT_SENTINEL_3e7f6c9a ]]
! rg -a -q ABLA_UNUSED_DEFAULT_SENTINEL_3e7f6c9a "$out/supplied"
rg -a -q ABLA_UNUSED_DEFAULT_SENTINEL_3e7f6c9a "$out/needed"
"$compiler" build tests/cases/lazy-defaults/build-wasm.ab -o "$out/wasm-driver" --no-cache
"$out/wasm-driver"
node tests/cases/lazy-defaults/run.mjs "$out/lazy.wasm"
echo 'defaults run only when omitted; unused pure defaults are removed in release'
