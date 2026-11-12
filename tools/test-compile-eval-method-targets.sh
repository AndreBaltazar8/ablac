#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/compile-eval-method-targets
mkdir -p "$out"
"$compiler" build tests/cases/compile-eval-method-targets/facts.ab --fast --no-cache \
    -o "$out/facts" > "$out/facts.log" 2>&1
status=0
"$out/facts" || status=$?
[[ $status == 42 ]] || { echo "method facts failed: $status" >&2; exit 1; }
for name in unrelated selected interface generic default-interface default-safe; do
    for tier in interp jit auto; do
        ABLA_COMPILE_EVAL=$tier ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build \
            "tests/cases/compile-eval-method-targets/build-$name.ab" -o "$out/builder" --fast --no-cache \
            > "$out/$name-$tier.log" 2>&1
        "$out/builder"
        cp "$out/$name.wasm" "$out/$name-$tier.wasm"
    done
    cmp "$out/$name-interp.wasm" "$out/$name-jit.wasm"
    cmp "$out/$name-interp.wasm" "$out/$name-auto.wasm"
done
python3 - <<'PY'
from pathlib import Path
for tier in ['jit', 'auto']:
    for name in ['unrelated', 'selected', 'interface', 'generic', 'default-interface', 'default-safe']:
        source = Path(f'tests/cases/compile-eval-method-targets/{name}.ab').read_bytes()
        marker = source.index(b'val H = #') + len(b'val H = ')
        lines = Path(f'build/compile-eval-method-targets/{name}-{tier}.log').read_text().splitlines()
        if name == 'unrelated':
            assert any(s.startswith('note[ct-jit]: native at ') and s.endswith(f'{name}.ab:{marker}') for s in lines), lines
            assert not any('interpreted at' in s for s in lines), lines
        else:
            hits = [s for s in lines if s.startswith(f'note[ct-jit]: interpreted at {marker + 1}:')]
            assert len(hits) == 1, lines
            if name in ['selected', 'generic']:
                assert 'adoptNativeString:' in hits[0], hits
PY
node --input-type=module - "$out" <<'NODE'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const out = process.argv[2];
const {instance} = await WebAssembly.instantiate(fs.readFileSync(`${out}/unrelated-jit.wasm`));
const e = instance.exports;
let digest = '';
for (let i = 0; i < Number(e.resultSize()); ++i) digest += String.fromCharCode(Number(e.resultByte(BigInt(i))));
assert.equal(digest, 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
for (const [name, size] of [['selected',0],['interface',4],['generic',0],['default-interface',0],['default-safe',4]]) {
    const {instance} = await WebAssembly.instantiate(fs.readFileSync(`${out}/${name}-jit.wasm`));
    assert.equal(Number(instance.exports.resultSize()), size);
}
NODE
echo 'compile-time method targets: precise concrete reach, conservative dynamic reach and three-tier Wasm parity passed'
