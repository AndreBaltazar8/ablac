#!/usr/bin/env bash
# Compare native bounded header scanning with the previous checked parser on
# every prefix, arbitrary bytes, malformed lines and long headers, in both
# evaluators/profiles, under GC pressure and in a bare Wasm module.
set -euo pipefail
compiler=${1:-build/ablac.bin}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/http-request-scan"
mkdir -p "$out"
cd "$root"
for mode in interp jit; do
    if [[ $mode == interp ]]; then
        ABLA_COMPILE_EVAL=$mode "$compiler" build tests/cases/http-request-scan/main.ab \
            -o "$out/$mode" --no-cache >"$out/$mode.log" 2>&1 ||
            { cat "$out/$mode.log" >&2; exit 1; }
    else
        ABLA_COMPILE_EVAL=$mode "$compiler" build tests/cases/http-request-scan/main.ab \
            -o "$out/$mode" --fast --no-cache >"$out/$mode.log" 2>&1 ||
            { cat "$out/$mode.log" >&2; exit 1; }
    fi
    for stress in 0 1; do
        status=0
        ABLA_GC_STRESS=$stress ABLA_MAX_SECONDS=120 \
            "$root/tools/run-limited.sh" "$out/$mode" || status=$?
        [[ $status -eq 42 ]] || { echo "request scan: $mode stress=$stress exited $status" >&2; exit 1; }
    done
done
"$compiler" build tests/cases/http-request-scan/build.ab -o "$out/build" \
    --no-cache >"$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
node --input-type=module - "$out/module.wasm" <<'JS'
import { readFileSync } from 'node:fs';
const module = await WebAssembly.compile(readFileSync(process.argv[2]));
if (WebAssembly.Module.imports(module).length) throw new Error('unexpected import');
const instance = await WebAssembly.instantiate(module, {});
const result = instance.exports.run();
if (result !== 0 && result !== 0n) throw new Error(`request scan: ${result}`);
JS
echo 'HTTP request scan: previous-parser differential, interpreter/JIT, release/fast, GC stress and bare Wasm'
