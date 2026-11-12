#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/compile-eval-environment
mkdir -p "$out/project"
"$compiler" build tests/cases/compile-eval-environment/facts.ab --fast --no-cache -o "$out/facts" >"$out/facts.log" 2>&1
status=0
"$out/facts" || status=$?
[[ $status == 42 ]] || { echo "environment facts failed: $status" >&2; exit 1; }
for shape in direct global global-first; do
    cp "tests/cases/compile-eval-environment/$shape.ab" "$out/project/table.ab"
    printf 'compileCapabilities = ["environment"]\n' >"$out/project/abla.toml"
    for tier in interp jit auto; do rm -rf "$out/cache-$tier"; done
    for state in first warm changed; do
        value=first
        [[ $state != changed ]] || value=second
        for tier in interp jit auto; do
            ABLA_CT_ENV_TEST=$value ABLA_COMPILE_EVAL=$tier ABLA_COMPILE_EVAL_TRACE=1 \
                ABLA_CACHE_DIR="$root/$out/cache-$tier" "$compiler" build \
                tests/cases/compile-eval-environment/build.ab -o "$out/builder" --fast \
                >"$out/$shape-$state-$tier.log" 2>&1
            "$out/builder"
            cp "$out/table.wasm" "$out/$shape-$state-$tier.wasm"
            python3 - "$shape" "$state" "$tier" <<'PYCHECK'
from pathlib import Path
import hashlib, json, sys
shape, state, tier = sys.argv[1:]
out = Path('build/compile-eval-environment')
sidecars = list((out/f'cache-{tier}').glob('native-wasm32-module-*.inputs'))
assert len(sidecars) == 1, sidecars
p = sidecars[0]; data = p.read_bytes()
assert b'abla-input:environment:ABLA_CT_ENV_TEST' in data, data
snapshot = [str(p), p.stat().st_mtime_ns, hashlib.sha256(data).hexdigest()]
if state != 'first':
    before = json.loads((out/f'{shape}-first-{tier}.json').read_text())
    if state == 'warm': assert snapshot == before, (snapshot, before)
    else: assert snapshot[0] == before[0] and snapshot[2] != before[2], (snapshot, before)
(out/f'{shape}-{state}-{tier}.json').write_text(json.dumps(snapshot))
if tier != 'interp':
    source = (out/'project/table.ab').read_bytes()
    lines = (out/f'{shape}-{state}-{tier}.log').read_text().splitlines()
    pos = source.index(b'val TABLE = #') + len(b'val TABLE = ')
    native = [s for s in lines if s.startswith('note[ct-jit]: native at ') and s.endswith(f'table.ab:{pos}')]
    expression_pos = pos + 1 + (source[pos+1:pos+2] == b'(')
    fallback = [s for s in lines if s.startswith(f'note[ct-jit]: interpreted at {expression_pos}:')]
    if shape == 'direct':
        assert len(native) == (0 if state == 'warm' else 1), lines
        assert not fallback, lines
    elif state != 'warm':
        assert len(fallback) == 1 and 'global ASSET_HOST initializer reaching compilerEnvironment' in fallback[0], lines
        assert not native, lines
PYCHECK
        done
        cmp "$out/$shape-$state-interp.wasm" "$out/$shape-$state-jit.wasm"
        cmp "$out/$shape-$state-interp.wasm" "$out/$shape-$state-auto.wasm"
        node --input-type=module - "$out/table.wasm" "$shape" "$value" <<'NODE'
import fs from 'node:fs';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
const {instance} = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]));
const e = instance.exports;
let actual = '';
for (let i=0; i<Number(e.tableSize()); ++i) actual += String.fromCharCode(Number(e.tableByte(BigInt(i))));
const value = process.argv[4];
assert.equal(actual, process.argv[3] === 'direct' ? crypto.createHash('sha256').update(value).digest('hex') : `${value}:${value}`);
NODE
    done
    # Same source, cache and output after a successful granted build: revoke authorization.
    printf 'compileCapabilities = []\n' >"$out/project/abla.toml"
    for tier in interp jit auto; do
        if ABLA_CT_ENV_TEST=secret ABLA_COMPILE_EVAL=$tier ABLA_COMPILE_EVAL_TRACE=1 \
            ABLA_CACHE_DIR="$root/$out/cache-$tier" "$compiler" build \
            tests/cases/compile-eval-environment/build.ab -o "$out/builder" --fast \
            >"$out/$shape-revoked-$tier.log" 2>&1; then
            echo 'revoked environment grant accepted' >&2; exit 1
        fi
        grep -q 'compile.capability-not-authorized:environment' "$out/$shape-revoked-$tier.log"
    done
    # Manifest authorization alone does not grant the source's environment effect.
    printf 'compileCapabilities = ["environment"]\n' >"$out/project/abla.toml"
    sed '/#compilerGrant("environment")/d' "tests/cases/compile-eval-environment/$shape.ab" >"$out/project/table.ab"
    for tier in interp jit auto; do
        if ABLA_CT_ENV_TEST=secret ABLA_COMPILE_EVAL=$tier "$compiler" build \
            tests/cases/compile-eval-environment/build.ab -o "$out/builder" --fast --no-cache \
            >"$out/$shape-denied-$tier.log" 2>&1; then
            echo 'ungranted environment effect accepted' >&2; exit 1
        fi
        grep -q 'compile.effect-denied:environment' "$out/$shape-denied-$tier.log"
    done
done
echo 'compile-time environment bridge: exact prototype, grants, cache invalidation/revocation and three-tier Wasm parity passed'
