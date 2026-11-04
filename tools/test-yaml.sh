#!/usr/bin/env bash
# YAML values, emit and lossless edits across native, CT interpreter/JIT, Wasm.
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
compile tests/cases/yaml/edit-probe.ab --fast --no-cache -o "$out/edit-probe"
python3 tests/cases/yaml/edit-check.py "$out/edit-probe" "$out"
ABLA_GC_STRESS=1 python3 tests/cases/yaml/edit-check.py "$out/edit-probe" "$out"
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode compile tests/cases/yaml/all-phases.ab --fast --no-cache -o "$out/phases-$mode"
    status=0
    "$out/phases-$mode" || status=$?
    [[ $status == 42 ]] || { echo "YAML $mode: exited $status" >&2; exit 1; }
done
status=0
ABLA_GC_STRESS=1 "$out/phases-interp" || status=$?
[[ $status == 42 ]]
compile tests/cases/yaml/all-phases.ab --no-cache -o "$out/phases-release"
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
echo 'YAML: parser/emitter/lossless edits, rollback, anchors, GC stress, interp/JIT and Wasm passed'
