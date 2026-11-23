#!/usr/bin/env bash
# Host providers do not execute their library bodies in a native CT slice.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler=$root/$compiler
cd "$root"
. tools/lib/ct-auto-trace.sh
export ABLA_DEBUG=0 ABLA_COMPILE_EVAL_TRACE=1
fixture=tests/cases/compile-eval-file-state
out=build/compile-eval-file-state
mkdir -p "$out"
"$compiler" build "$fixture/facts.ab" --fast --no-cache -o "$out/facts" > "$out/facts.log" 2>&1
status=0
"$out/facts" || status=$?
if [[ $status != 42 ]]; then
    printf 'compile-eval-file-state: provider state facts exited %s, expected 42\n' "$status" >&2
    exit 1
fi
for mode in interp jit auto; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build "$fixture/main.ab" --fast --no-cache \
        -o "$out/native" > "$out/native-$mode.log" 2>&1
    ABLA_COMPILE_EVAL=$mode "$compiler" build "$fixture/build.ab" --fast --no-cache \
        -o "$out/builder" > "$out/wasm-$mode.log" 2>&1
    "$out/builder"
    cp "$out/native" "$out/native-$mode.bin"
    cp "$out/main.wasm" "$out/main-$mode.wasm"
    status=0
    "$out/native" || status=$?
    [[ $status == 42 ]]
    ABLA_COMPILE_EVAL=$mode "$compiler" build "$fixture/lookalike.ab" --fast --no-cache \
        -o "$out/lookalike" > "$out/lookalike-$mode.log" 2>&1
    status=0
    "$out/lookalike" || status=$?
    [[ $status == 42 ]]
done
for target in native wasm; do
    grep -Eq '^note\[ct-jit\]: native at .*compile-eval-file-state/main[.]ab:' "$out/$target-jit.log"
    ct_auto_follows_jit "$out/$target-auto.log" "$out/$target-jit.log"
done
for mode in jit auto; do
    cmp "$out/native-interp.bin" "$out/native-$mode.bin"
    cmp "$out/main-interp.wasm" "$out/main-$mode.wasm"
    grep -q 'ordinary mutable global RECEIPTS' "$out/lookalike-$mode.log"
done
node - "$out/main-jit.wasm" <<'JS'
const bytes = require("node:fs").readFileSync(process.argv[2]);
const result = new WebAssembly.Instance(new WebAssembly.Module(bytes)).exports.run();
if (result !== 42n) throw new Error(`file provider returned ${result}`);
JS
echo 'compile-eval-file-state: native and Wasm provider parity, plus same-name user write control, passed'
