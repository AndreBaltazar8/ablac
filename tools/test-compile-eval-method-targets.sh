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
for tier in jit auto; do
    for name in unrelated selected interface generic default-interface default-safe; do
        # Byte offset just past `val H = ` is where the compile-time call starts.
        marker=$(( $(grep -boa 'val H = #' "tests/cases/compile-eval-method-targets/$name.ab" | head -n 1 | cut -d: -f1) + 8 ))
        log="$out/$name-$tier.log"
        if [[ $name == unrelated ]]; then
            awk -v tail="$name.ab:$marker" 'index($0, "note[ct-jit]: native at ") == 1 && substr($0, length($0) - length(tail) + 1) == tail { found = 1 } END { exit !found }' "$log" \
                || { cat "$log" >&2; echo "method targets: $name $tier was not native at $marker" >&2; exit 1; }
            ! grep -qF 'interpreted at' "$log" || { cat "$log" >&2; echo "method targets: $name $tier interpreted" >&2; exit 1; }
        else
            prefix="note[ct-jit]: interpreted at $((marker + 1)):"
            hits=$(awk -v p="$prefix" 'index($0, p) == 1' "$log")
            [[ -n $hits && $(printf '%s\n' "$hits" | wc -l) -eq 1 ]] \
                || { cat "$log" >&2; echo "method targets: $name $tier needs exactly one interpreted note at $((marker + 1))" >&2; exit 1; }
            case $name in selected|generic)
                [[ $hits == *'adoptNativeString:'* ]] || { echo "method targets: $name $tier lacks adoptNativeString" >&2; exit 1; } ;;
            esac
        fi
    done
done
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
