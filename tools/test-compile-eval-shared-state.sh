#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
# host, wasm, or both (the default): the suite runs the two as separate entries, which run at once.
targets=${2:-host wasm}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/compile-eval-shared-state/${targets// /-}
cases=tests/cases/compile-eval-shared-state
mkdir -p "$out"
for source in "$cases"/*.ab; do
    name=${source##*/}; name=${name%.ab}
    case $name in
        readonly) expected=9 ;;
        delegate-get|delegate-local) expected=1,1,1 ;;
        delegate-set) expected=0,1,1 ;;
        member-unrelated|member-generic) expected=5,7 ;;
        interface-class) expected=5,2 ;;
        member-drop-unrelated) expected=5,2 ;;
        operator-builtin|operator-compound) expected=5,3 ;;
        operator-scalar) expected=6,6 ;;
        operator-generic) expected=3,3 ;;
        operator-unary) expected=-3,-4 ;;
        operator-string) expected=ab,1x ;;
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
    for target in $targets; do
        # interp and jit: `auto` is `jit` until the tier policy lands (bootstrapCtMode, ct_eval.ab: every caller asks
        # only whether the mode is "interp"), so a third pass built the same thing again.
        for tier in interp jit; do
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
                    grep '^note\[ct-jit\]: native at ' "$log" | grep -F "readonly.ab:$pos" >/dev/null
                elif [[ $name == member-* || $name == interface-* || $name == operator-builtin || $name == operator-scalar || $name == operator-generic || $name == operator-compound || $name == operator-unary || $name == operator-string ]]; then
                    # X (a call of B.touch; the sum of two ints) and Y (a call of A.touch or of Box.plus: a write
                    # of `shared`).
                    # Every slice carries the checker's resolved targets (host ones too since #828), so X reaches B.touch
                    # alone and stays native (a generic body is one copy per instantiation, go<B> and go<A>, each with its
                    # own fact; the slice carries the classes' interface, #813); operator-generic's copies are not
                    # narrowed on a built-in fact. Y always runs in the interpreter.
                    posX=$(( $(offset 'val X = #') + 8 ))
                    posY=$(( $(offset 'val Y = #') + 8 ))
                    # Y writes `shared`: native when every site reaching it is (the native tier owns it for the pass),
                    # else interpreted; either way once.
                    grep '^note\[ct-jit\]: native at ' "$log" | grep -F "$name.ab:$posY" >/dev/null ||
                        grep -Fq "note[ct-jit]: interpreted at $((posY+1)):" "$log" ||
                        { echo "$name $target $tier: Y was neither native nor interpreted" >&2; exit 1; }
                    if [[ $name != operator-generic ]]; then
                        grep '^note\[ct-jit\]: native at ' "$log" | grep -F "$name.ab:$posX" >/dev/null ||
                            { echo "$name $target $tier: X was not native" >&2; exit 1; }
                    else
                        # operator-generic's copies reach `shared` too: X runs in Y's tier (both native when the
                        # native tier owns `shared`).
                        grep '^note\[ct-jit\]: native at ' "$log" | grep -F "$name.ab:$posX" >/dev/null ||
                            grep -Fq "note[ct-jit]: interpreted at $((posX+1)):" "$log" ||
                            { echo "$name $target $tier: X was neither native nor interpreted" >&2; exit 1; }
                    fi
                elif [[ $name == delegate-* ]]; then
                    # A delegated binding is rewritten before analysis, which moves the sites: count them.
                    sites=4
                    [[ $name == delegate-forward ]] || sites=3
                    [[ $(grep -c "^note\[ct-jit\]: interpreted at " "$log") -eq $sites ]] ||
                        { echo "$name: expected $sites interpreted sites" >&2; exit 1; }
                    ! grep -q "^note\[ct-jit\]: native at .*$name.ab" "$log"
                else
                    # A, B and D share a written global. The native tier owns it for the pass when every site that
                    # reaches it is native (ct_jit.ab, bootstrapCtOwnableReason); otherwise all of them run in the
                    # interpreter. Never some of each: the two copies would diverge (the results above would differ).
                    native=0
                    interpreted=0
                    for binding in A B D; do
                        pos=$(offset "val $binding = #")
                        pos=$((pos + 8))
                        if grep '^note\[ct-jit\]: native at ' "$log" | grep -F "$name.ab:$pos" >/dev/null; then
                            native=$((native + 1))
                        else
                            fallback=$(grep -F "note[ct-jit]: interpreted at $((pos+1)):" "$log")
                            [[ $(printf '%s\n' "$fallback" | wc -l) -eq 1 ]] ||
                                { echo "$name $target $tier: $binding neither native nor interpreted once" >&2; exit 1; }
                            interpreted=$((interpreted + 1))
                        fi
                    done
                    [[ $native -eq 0 || $interpreted -eq 0 ]] ||
                        { echo "$name $target $tier: sites sharing a global ran in both tiers ($native native)" >&2; exit 1; }
                fi
            fi
        done
        if [[ $target == wasm ]]; then
            cmp "$out/$name-interp.wasm" "$out/$name-jit.wasm"
        fi
    done
done
echo "compile-time shared state ($targets): interp/jit and order parity; sites sharing a written global run in one tier, read-only tables stay native"
