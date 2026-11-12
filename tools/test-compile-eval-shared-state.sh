#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/compile-eval-shared-state
cases=tests/cases/compile-eval-shared-state
mkdir -p "$out"
for source in "$cases"/*.ab; do
    name=${source##*/}; name=${name%.ab}
    case $name in
        readonly) expected=9 ;;
        delegate-get|delegate-local) expected=1,1,1 ;;
        delegate-set) expected=0,1,1 ;;
        *-forward) expected=1,1,1,2 ;;
        *-reverse) expected=0,1,2,2 ;;
        *-read-first) expected=0,0,1,2 ;;
        *) echo "missing shared-state oracle: $name" >&2; exit 1 ;;
    esac
    cat >"$out/build.ab" <<EOF
import "abla/wasm/build"
val built = #wasmBuildModule("shared-state", "$source", "$out/result.wasm", true, false)
fun main: int = if (built) 0 else 1
EOF
    for target in host wasm; do
        for tier in interp jit auto; do
            input=$source
            [[ $target != wasm ]] || input="$out/build.ab"
            ABLA_COMPILE_EVAL=$tier ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build "$input" \
                -o "$out/program" --fast --no-cache >"$out/$name-$target-$tier.log" 2>&1
            if [[ $target == host ]]; then
                actual=$("$out/program")
                [[ $actual == "$expected" ]] || { echo "$name $target $tier: $actual != $expected" >&2; exit 1; }
            else
                "$out/program"
                cp "$out/result.wasm" "$out/$name-$tier.wasm"
                node --input-type=module - "$out/result.wasm" "$expected" <<'NODE'
import fs from 'node:fs';
import assert from 'node:assert/strict';
const {instance} = await WebAssembly.instantiate(fs.readFileSync(process.argv[2]), {abla_host: {write: () => 0}});
const e = instance.exports;
let actual;
if (e.resultValue) actual = String(e.resultValue());
else {
    actual = '';
    for (let i=0; i<Number(e.resultSize()); ++i) actual += String.fromCharCode(Number(e.resultByte(BigInt(i))));
}
assert.equal(actual, process.argv[3]);
NODE
            fi
            if [[ $tier != interp ]]; then
                log="$out/$name-$target-$tier.log"
                offset() {
                    LC_ALL=C awk -v needle="$1" 'index($0, needle) { print bytes + index($0, needle) - 1; found=1; exit } { bytes += length($0)+1 } END { if (!found) exit 1 }' "$source"
                }
                if [[ $name == readonly ]]; then
                    pos=$(offset '#lookup()')
                    grep '^note\[ct-jit\]: native at ' "$log" | grep -Fq "readonly.ab:$pos"
                elif [[ $name == delegate-* ]]; then
                    # A delegated binding is rewritten before analysis, which moves the sites: count them.
                    sites=4
                    [[ $name == delegate-forward ]] || sites=3
                    [[ $(grep -c "^note\[ct-jit\]: interpreted at .*ordinary mutable global " "$log") -eq $sites ]] ||
                        { echo "$name: expected $sites interpreted sites" >&2; exit 1; }
                    ! grep -q "^note\[ct-jit\]: native at .*$name.ab" "$log"
                else
                    for binding in A B D; do
                        pos=$(offset "val $binding = #")
                        pos=$((pos + 8))
                        if grep '^note\[ct-jit\]: native at ' "$log" | grep -Fq "$name.ab:$pos"; then
                            echo "mutable site unexpectedly native: $name:$pos" >&2; exit 1
                        fi
                        fallback=$(grep -F "note[ct-jit]: interpreted at $((pos+1)):" "$log")
                        [[ $(printf '%s\n' "$fallback" | wc -l) -eq 1 ]]
                        [[ $fallback == *'ordinary mutable global '* && $fallback == *'written at '* ]]
                    done
                fi
            fi
        done
        if [[ $target == wasm ]]; then
            cmp "$out/$name-interp.wasm" "$out/$name-jit.wasm"
            cmp "$out/$name-interp.wasm" "$out/$name-auto.wasm"
        fi
    done
done
echo 'compile-time shared state: host/Wasm three-tier and order parity; mutable components fall back, read-only tables stay native'
