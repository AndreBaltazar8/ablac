#!/usr/bin/env bash
# Pure YAML parsing across native, compile-time interpreter/JIT, and Wasm.
set -euo pipefail
compiler=${1:-build/ablac.bin}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/yaml"
mkdir -p "$out"
cd "$root"
compile() { (ulimit -s 131072; "$compiler" build "$@"); }
compile tests/cases/yaml/probe.ab --fast --no-cache -o "$out/probe"
python3 tests/cases/yaml/check.py "$out/probe" "$out"
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode compile tests/cases/yaml/phases.ab --fast --no-cache -o "$out/phases-$mode"
    status=0
    "$out/phases-$mode" || status=$?
    [[ $status == 42 ]] || { echo "YAML $mode: exited $status" >&2; exit 1; }
done
status=0
ABLA_GC_STRESS=1 "$out/phases-interp" || status=$?
[[ $status == 42 ]]
compile tests/cases/yaml/phases.ab --no-cache -o "$out/phases-release"
status=0
"$out/phases-release" || status=$?
[[ $status == 42 ]]
compile tests/cases/yaml/build-wasm.ab --fast --no-cache -o "$out/build-wasm"
"$out/build-wasm"
node --input-type=module - "$out/phases.wasm" <<'JS'
import { readFileSync } from 'node:fs';
const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
const result = instance.exports.check();
if (result !== 42 && result !== 42n) throw new Error(`YAML Wasm: ${result}`);
JS
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode compile tests/cases/yaml/emit.ab --fast --no-cache -o "$out/emit-$mode"
    status=0
    "$out/emit-$mode" || status=$?
    [[ $status == 42 ]]
done
status=0
ABLA_GC_STRESS=1 "$out/emit-interp" || status=$?
[[ $status == 42 ]]
compile tests/cases/yaml/build-wasm-emit.ab --fast --no-cache -o "$out/build-wasm-emit"
"$out/build-wasm-emit"
node --input-type=module - "$out/emit.wasm" <<'JS'
import { readFileSync } from 'node:fs';
const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
const result = instance.exports.check();
if (result !== 42 && result !== 42n) throw new Error(`YAML emit Wasm: ${result}`);
JS
echo 'YAML: parser/emitter native, GC stress, compile-time interp/JIT and Wasm passed'
