#!/usr/bin/env bash
# abla/json under `#` in a Wasm32 build (#795): the compile-time native tier takes the JSON DOM/tape/error paths of a
# cross-target site, and everything it cannot prove stays in the evaluator. Per fixture (tests/cases/compile-eval-json):
# host and Wasm builds in interp, jit and auto give one result (the evaluator's, which the table below also pins), the
# three Wasm modules are byte-identical, and the trace shows which sites ran natively and why the others did not.
# intrinsics.ab compares the scanning intrinsics under `#` with their run-time answers for a hostile corpus.
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/compile-eval-json
cases=tests/cases/compile-eval-json
rm -rf "$out"
mkdir -p "$out"
# fixture|(unused)|native sites in a Wasm jit/auto build|interpreted sites|the reason every interpreted site names
table=(
    "dom|-|2|0|"
    "errors|-|2|0|"
    "document|-|1|0|"
    "limits-global|-|0|1|ordinary mutable global"
    "stringify|-|0|1|ordinary mutable global"
    "float|-|0|1|expression float"
    "mutate-empty|-|0|3|ordinary mutable global"
)
wasm_build() { # source output
    cat >"$out/build.ab" <<AB
import "abla/wasm/build"
val built = #wasmBuildModule("json", "$1", "$2", true, false)
fun main: int = if (built) 0 else 1
AB
}
wasm_result() { # module
    node --input-type=module - "$1" <<'NODE'
import fs from 'node:fs';
const {instance} = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]), {abla_host: {write: () => 0}});
const e = instance.exports;
const bytes = [];
for (let i = 0; i < Number(e.resultSize()); ++i) bytes.push(Number(e.resultByte(BigInt(i))));
process.stdout.write(new TextDecoder().decode(new Uint8Array(bytes)));
NODE
}
fail() { echo "compile-eval-json: $*" >&2; exit 1; }
for row in "${table[@]}"; do
    IFS="|" read -r name _ native interpreted reason <<<"$row"
    source=$cases/$name.ab
    expected=$(cat "$cases/$name.expected")
    for target in host wasm; do
        for tier in interp jit auto; do
            input=$source
            if [[ $target == wasm ]]; then wasm_build "$source" "$out/result.wasm"; input=$out/build.ab; fi
            log=$out/$name-$target-$tier.log
            ABLA_COMPILE_EVAL=$tier ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build "$input" -o "$out/program" --fast --no-cache >"$log" 2>&1 ||
                { cat "$log" >&2; fail "$name $target $tier: the build failed"; }
            if [[ $target == host ]]; then
                actual=$("$out/program")
            else
                "$out/program"
                cp "$out/result.wasm" "$out/$name-$tier.wasm"
                actual=$(wasm_result "$out/result.wasm")
            fi
            [[ $actual == "$expected" ]] || fail "$name $target $tier: [$actual] != [$expected]"
            if [[ $target == wasm && $tier != interp ]]; then
                nativeCount=$(grep -c '^note\[ct-jit\]: native at ' "$log" || true)
                interpretedCount=$(grep -c '^note\[ct-jit\]: interpreted at ' "$log" || true)
                # The build program's own site (wasmBuildModule) is native too: one more than the fixture's.
                [[ $((nativeCount - 1)) -eq $native ]] ||
                    fail "$name $target $tier: $((nativeCount - 1)) native sites, expected $native"
                [[ $interpretedCount -eq $interpreted ]] ||
                    fail "$name $target $tier: $interpretedCount interpreted sites, expected $interpreted"
                if [[ -n $reason ]]; then
                    [[ $(grep '^note\[ct-jit\]: interpreted at ' "$log" | grep -c -F "$reason") -eq $interpreted ]] ||
                        fail "$name $target $tier: an interpreted site does not name [$reason]"
                fi
            fi
        done
    done
    cmp "$out/$name-interp.wasm" "$out/$name-jit.wasm"
    cmp "$out/$name-interp.wasm" "$out/$name-auto.wasm"
done
# A parsed value that reaches the program is a fresh copy (host: three tiers give the program's own line).
for tier in interp jit auto; do
    ABLA_COMPILE_EVAL=$tier "$compiler" build $cases/fresh.ab -o "$out/program" --fast --no-cache >"$out/fresh-$tier.log" 2>&1 ||
        { cat "$out/fresh-$tier.log" >&2; fail "fresh $tier: the build failed"; }
    [[ $("$out/program") == $(cat $cases/fresh.expected) ]] || fail "fresh $tier: $("$out/program")"
done
# The scanning intrinsics, under `#` and at run time, on a hostile corpus: host and Wasm, all tiers.
source=$cases/intrinsics.ab
for target in host wasm; do
    for tier in interp jit auto; do
        input=$source
        if [[ $target == wasm ]]; then
            cp "$source" "$out/intrinsics-wasm.ab"
            printf '\n@export("check")\nfun wasmCheck(): int = main()\n' >>"$out/intrinsics-wasm.ab"
            wasm_build "$out/intrinsics-wasm.ab" "$out/intrinsics.wasm"
            input=$out/build.ab
        fi
        ABLA_COMPILE_EVAL=$tier "$compiler" build "$input" -o "$out/program" --fast --no-cache >"$out/intrinsics-$target-$tier.log" 2>&1 ||
            { cat "$out/intrinsics-$target-$tier.log" >&2; fail "intrinsics $target $tier: the build failed"; }
        if [[ $target == host ]]; then
            "$out/program" | grep -q '^json intrinsics ok ' || fail "intrinsics $target $tier: the digests differ"
        else
            "$out/program"
            node --input-type=module - "$out/intrinsics.wasm" <<'NODE'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const {instance} = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]), {abla_host: {write: () => 0}});
assert.equal(Number(instance.exports.check()), 0);
NODE
        fi
    done
done
echo 'compile-eval-json: JSON DOM, tape and error paths run natively in a Wasm build, three-tier parity, intrinsics agree, floats and writable shared arrays stay interpreted'
