#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
out="$project_root/build/compile-eval-cross-target"
mkdir -p "$out"
export ABLA_DEBUG=0
"$compiler" build tests/cases/compile-eval-cross-target/extern-signatures.ab --fast --no-cache -o "$out/extern-signatures"
set +e
"$out/extern-signatures"
signature_status=$?
set -e
[[ $signature_status -eq 42 ]]
for mode in interp jit auto; do
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build \
        tests/cases/compile-eval-cross-target/build.ab -o "$out/builder-$mode" --fast --no-cache \
        > "$out/$mode.log" 2>&1
    "$out/builder-$mode"
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build \
        tests/cases/compile-eval-cross-target/build-fallback.ab -o "$out/fallback-builder-$mode" --fast --no-cache \
        >> "$out/$mode.log" 2>&1
    "$out/fallback-builder-$mode"
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build \
        tests/cases/compile-eval-cross-target/build-implicit.ab -o "$out/implicit-builder-$mode" --fast --no-cache \
        > "$out/implicit-$mode.log" 2>&1
    "$out/implicit-builder-$mode"
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build \
        tests/cases/compile-eval-cross-target/build-collision.ab -o "$out/collision-builder-$mode" --fast --no-cache \
        > "$out/collision-$mode.log" 2>&1
    "$out/collision-builder-$mode"
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build \
        tests/cases/compile-eval-cross-target/build-floats.ab -o "$out/floats-builder-$mode" --fast --no-cache \
        > "$out/floats-$mode.log" 2>&1
    "$out/floats-builder-$mode"
    cp "$out/floats.wasm" "$out/floats-$mode.wasm"
    cp "$out/collision.wasm" "$out/collision-$mode.wasm"
    cp "$out/implicit.wasm" "$out/implicit-$mode.wasm"
    cp "$out/portable.wasm" "$out/portable-$mode.wasm"
    cp "$out/fallback.wasm" "$out/fallback-$mode.wasm"
done
for mode in jit auto; do
    cmp "$out/portable-interp.wasm" "$out/portable-$mode.wasm"
    cmp "$out/fallback-interp.wasm" "$out/fallback-$mode.wasm"
    cmp "$out/implicit-interp.wasm" "$out/implicit-$mode.wasm"
    cmp "$out/collision-interp.wasm" "$out/collision-$mode.wasm"
    cmp "$out/floats-interp.wasm" "$out/floats-$mode.wasm"
    [[ $(grep -c 'interpreted at' "$out/floats-$mode.log") -eq 7 ]]
    ! grep -q 'native at .*[/]floats.ab:' "$out/floats-$mode.log"
    grep -q 'interpreted at .*cross-target host runtime declaration collision: getpid' "$out/collision-$mode.log"
    grep -q 'interpreted at .*cross-target implicit runtime dependency' "$out/implicit-$mode.log"
    # The probe, indirect call, builtin-looking user method, selected native
    # arm and raw pointer operation fall back. The skipped native arm, file
    # read and SHA remain native.
    [[ $(grep -c 'interpreted at' "$out/$mode.log") -eq 10 ]]
    grep -q 'interpreted at .*cross-target site reaches .*ablaU128NarrowTarget' "$out/$mode.log"
    grep -q 'interpreted at .*expression call.value' "$out/$mode.log"
    grep -q 'interpreted at .*cross-target site reaches abs:' "$out/$mode.log"
    grep -Eq 'interpreted at .*cross-target site reaches .*(pointerIsNull|nativeNullPointer)' "$out/$mode.log"
    [[ $(grep -c 'native at' "$out/$mode.log") -ge 7 ]]
    python3 - "$out/$mode.log" <<'PYTRACE'
import pathlib, re, sys
source = pathlib.Path('tests/cases/compile-eval-cross-target/fallback.ab').read_bytes()
lines = pathlib.Path(sys.argv[1]).read_text().splitlines()
for name, tier in [('SKIPPED', 'native'), ('SELECTED', 'interpreted'), ('METHOD', 'interpreted'), ('RAW', 'interpreted'), ('QUERY', 'interpreted'), ('PARSER', 'interpreted'), ('GLOBAL', 'interpreted'), ('FAKE', 'interpreted'), ('WHEN', 'interpreted')]:
    match = re.search(rb'\bval\s+' + name.encode() + rb'\s*=\s*#', source)
    assert match, name
    marker = match.end() - 1
    expression = marker + 1
    while source[expression:expression+1].isspace(): expression += 1
    if tier == 'native':
        assert any(line.startswith('note[ct-jit]: native at ') and line.endswith(f'fallback.ab:{marker}') for line in lines), (name, lines)
        assert not any(line.startswith(f'note[ct-jit]: interpreted at {expression}:') for line in lines), name
    else:
        hits = [line for line in lines if line.startswith(f'note[ct-jit]: interpreted at {expression}: cross-target site reaches ')]
        assert len(hits) == 1, (name, expression, lines)
        if name in ('SELECTED', 'METHOD', 'GLOBAL'): assert 'abs:' in hits[0], (name, hits)
        if name == 'QUERY': assert 'compilerFindFunction:' in hits[0], (name, hits)
        if name == 'PARSER': assert 'syntaxKind:' in hits[0], (name, hits)
        if name == 'FAKE': assert 'expression float' in hits[0], (name, hits)
PYTRACE
done
ABLA_COMPILE_EVAL=jit ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build \
    tests/cases/compile-eval-cross-target/build-heavy.ab -o "$out/heavy-builder" --fast --no-cache \
    > "$out/heavy.log" 2>&1
"$out/heavy-builder"
! grep -q 'interpreted at' "$out/heavy.log"
grep -q 'native at' "$out/heavy.log"
# A missing hosted platform file must refuse native preparation, never emit
# an empty successful overlay. Direct Wasm object building avoids a host parent
# graph that would itself need the intentionally absent file.
rm -rf "$out/missing-root"
mkdir -p "$out/missing-root"
cp -a "$project_root/stdlib" "$out/missing-root/stdlib"
rm "$out/missing-root/stdlib/abla/runtime/platform/host.ab"
ABLA_SYSROOT="$out/missing-root" ABLA_COMPILE_EVAL=jit ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build \
    tests/cases/compile-eval-cross-target/simple.ab --target-triple wasm32-unknown-unknown \
    --object-format wasm --emit object --no-cache -o "$out/missing.o" > "$out/missing.log" 2>&1
grep -q 'interpreted at .*cross-target host runtime file unavailable' "$out/missing.log"

node - "$out" <<'JS'
const fs = require('fs');
(async () => {
  for (const [name, expected] of [['portable', 42n], ['fallback', 42n], ['implicit', 42n], ['collision', 42n], ['floats', 42n], ['heavy', 12810n]]) {
    const module = new WebAssembly.Module(fs.readFileSync(`${process.argv[2]}/${name}.wasm`));
    const imports = {};
    for (const entry of WebAssembly.Module.imports(module)) {
      if (entry.kind !== 'function' || entry.name !== 'abs') throw new Error(`unexpected import ${JSON.stringify(entry)}`);
      (imports[entry.module] ||= {}).abs = Math.abs;
    }
    const instance = new WebAssembly.Instance(module, imports);
    const actual = instance.exports.run();
    if (actual !== expected) throw new Error(`${name}: got ${actual}, expected ${expected}`);
  }
})().catch(error => { console.error(error); process.exit(1); });
JS
echo 'compile-eval-cross-target: portable sites are native with byte-identical wasm; target probes fall back; heavy site finishes'
