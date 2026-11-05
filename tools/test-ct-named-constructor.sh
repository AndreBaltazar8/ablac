#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/ct-named-constructor-test
mkdir -p "$out"
expect42() {
    local status=0
    "$@" || status=$?
    [[ $status == 42 ]] || { echo "CT named constructor: expected42, got$status: $*" >&2; exit 1; }
}
for mode in interp jit; do
    for case in main direct qualified staged; do
        ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build \
            "tests/cases/ct-named-constructor/$case.ab" --fast --no-cache \
            -o "$out/$case-$mode" >"$out/$case-$mode.log" 2>&1
        expect42 "$out/$case-$mode"
    done
    # Cursor handlers deliberately use the interpreter even in JIT mode.
    # The ordinary staged expression above must actually use the native tier.
    if [[ $mode == jit ]]; then grep -q 'native at' "$out/staged-jit.log"; fi
    if ABLA_COMPILE_EVAL=$mode "$compiler" build \
        tests/cases/ct-named-constructor/unsupported.ab --fast --no-cache \
        -o "$out/unsupported-$mode" >"$out/unsupported-$mode.log" 2>&1; then
        echo 'unsupported expression in a subparser handler silently succeeded' >&2
        exit 1
    fi
    grep -q 'error\[E_EVAL_EXPRESSION\]' "$out/unsupported-$mode.log"
    grep -q 'context\[subparser\]' "$out/unsupported-$mode.log"
done
# Invalid early calls must use the same matching diagnostics as normalization.
for spec in 'unknown:UNKNOWN:HiddenLeafValue(noSuch = 40)' 'duplicate:DUPLICATE:HiddenLeafValue(value = 40, value = 41)' 'order:ORDER:HiddenLeafValue(value = 40, 2)' 'missing:MISSING:PriorDefault(extra = 2)'; do
    name=${spec%%:*}
    rest=${spec#*:}
    error=${rest%%:*}
    call=${rest#*:}
    cat > "$out/invalid-$name.ab" <<ABLA
import "$root/tests/cases/ct-named-constructor/leaf.ab"
import "abla/compiler/parser"
compile fun invalidCall(cursor: ParserCursor): SyntaxExpression {
    parserExpect(cursor, "(")
    parserExpect(cursor, ")")
    val ignored = $call
    syntaxInteger(42)
}
#compilerRegisterSubparser("invalidCall", invalidCall)
fun main: int = \$invalidCall()
ABLA
    if ABLA_COMPILE_EVAL=interp "$compiler" build "$out/invalid-$name.ab" \
        --fast --no-cache -o "$out/invalid-$name" >"$out/invalid-$name.log" 2>&1; then
        echo "invalid CT constructor $name unexpectedly built" >&2
        exit 1
    fi
    grep -q "error\[E_NAMED_ARGUMENT_$error\]" "$out/invalid-$name.log"
    grep -q 'context\[subparser\]' "$out/invalid-$name.log"
done
echo 'CT constructor names/defaults preserve values, source order and errors in direct/aliased interpreter and JIT paths'
