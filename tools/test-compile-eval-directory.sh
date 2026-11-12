#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/compile-eval-directory
mkdir -p "$out/project" "$out/input"
cp tests/cases/compile-eval-directory/lookup.ab "$out/project/lookup.ab"
printf 'compileCapabilities = ["filesystem.read"]\n' > "$out/project/abla.toml"
rm -f "$out/input/"*
# Each mode has a separate cache; every mutation reuses that mode's source,
# output and cache paths. Do not add --no-cache to these builds.
for mode in interp jit auto; do
    rm -rf "$out/cache-$mode"
done

for state in initial warm create remove rename content; do
    python3 - "$state" <<'PYINPUT'
from pathlib import Path
import os
import sys
p = Path('build/compile-eval-directory/input')
state = sys.argv[1]
if state == 'initial':
    # Create in reverse order, including a non-ASCII filename/content.
    for name, value in [('z.txt', 'zz'), ('α.txt', 'π'), ('a.txt', 'aa')]:
        (p/name).write_text(value)
elif state == 'create':
    (p/'m.txt').write_text('mm')
elif state == 'remove':
    (p/'z.txt').unlink()
elif state == 'rename':
    (p/'m.txt').rename(p/'n.txt')
elif state == 'content':
    target = p/'a.txt'
    before = target.stat()
    target.write_text('bb')  # same byte length and modification time
    os.utime(target, ns=(before.st_atime_ns, before.st_mtime_ns))
expected = ''.join(f'{entry.name}:{entry.read_text()}\n' for entry in sorted(p.iterdir()))
Path('build/compile-eval-directory/expected.txt').write_text(expected)
PYINPUT
    for mode in interp jit auto; do
        ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 \
            ABLA_CACHE_DIR="$root/$out/cache-$mode" "$compiler" build \
            tests/cases/compile-eval-directory/build.ab -o "$out/builder" --fast \
            > "$out/$state-$mode.log" 2>&1
        "$out/builder"
        cp "$out/table.wasm" "$out/$state-$mode.wasm"
        node --input-type=module - "$out/table.wasm" "$out/expected.txt" <<'NODE'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const {instance} = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]));
const e = instance.exports;
const bytes = Buffer.alloc(Number(e.tableSize()));
for (let i = 0; i < bytes.length; ++i) bytes[i] = Number(e.tableByte(BigInt(i)));
assert.deepEqual(bytes, fs.readFileSync(process.argv[3]));
NODE
        python3 - "$state" "$mode" <<'PYJOURNAL'
from pathlib import Path
import hashlib
import json
import sys
state, mode = sys.argv[1:]
out = Path('build/compile-eval-directory')
journals = list((out/f'cache-{mode}').glob('native-wasm32-module-*.inputs'))
assert len(journals) == 1, journals
journal = journals[0]
data = journal.read_bytes()
assert b'abla-input:entries:build/compile-eval-directory/input' in data
assert b'build/compile-eval-directory/input/a.txt' in data
snapshot = {'path': str(journal), 'mtime': journal.stat().st_mtime_ns,
            'hash': hashlib.sha256(data).hexdigest()}
if state != 'initial':
    previous = {'warm': 'initial', 'create': 'warm', 'remove': 'create',
                'rename': 'remove', 'content': 'rename'}[state]
    before = json.loads((out/f'{previous}-{mode}-journal.json').read_text())
    assert snapshot['path'] == before['path']
    if state == 'warm':
        assert snapshot == before, (snapshot, before)  # actual cache reuse
    else:
        assert snapshot['hash'] != before['hash'], (state, snapshot, before)
(out/f'{state}-{mode}-journal.json').write_text(json.dumps(snapshot))
PYJOURNAL
        if [[ $mode != interp ]]; then
            python3 - "$out/$state-$mode.log" "$out/project/lookup.ab" "$state" <<'PYTRACE'
from pathlib import Path
import sys
source = Path(sys.argv[2]).read_bytes()
position = source.index(b'#lookup()')
lines = Path(sys.argv[1]).read_text().splitlines()
native = [line for line in lines if line.startswith('note[ct-jit]: native at ') and line.endswith(f'lookup.ab:{position}')]
assert (len(native) == 0 if sys.argv[3] == 'warm' else len(native) == 1), lines
assert not any('interpreted at' in line for line in lines), lines
PYTRACE
        fi
    done
    cmp "$out/$state-interp.wasm" "$out/$state-jit.wasm"
    cmp "$out/$state-interp.wasm" "$out/$state-auto.wasm"
done
cmp "$out/initial-jit.wasm" "$out/warm-jit.wasm"
for pair in create:warm remove:create rename:remove content:rename; do
    state=${pair%:*}
    previous=${pair#*:}
    if cmp -s "$out/$previous-jit.wasm" "$out/$state-jit.wasm"; then
        echo "directory mutation $state did not change the module" >&2; exit 1
    fi
done

# Revoke the same child source's filesystem grant with caches still populated.
printf 'compileCapabilities = []\n' > "$out/project/abla.toml"
if ABLA_COMPILE_EVAL=jit ABLA_CACHE_DIR="$root/$out/cache-jit" "$compiler" build \
    tests/cases/compile-eval-directory/build.ab -o "$out/builder" --fast \
    > "$out/denied.log" 2>&1; then
    echo 'directory table reused a revoked filesystem grant' >&2; exit 1
fi
grep -q 'compile.capability-not-authorized:filesystem.read' "$out/denied.log"
echo 'directory compile-time table: native parity, stable sorting, journal invalidation and revocation passed'
