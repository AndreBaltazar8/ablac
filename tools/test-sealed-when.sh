#!/usr/bin/env bash
# A `when` whose arms are all `is` over a sealed subject (tests/cases/sealed-when): its last arm has no type
# test and the `when` no non-exhaustive panic, and the `when`s that keep the panic share one message global.
# The same score natively (release and --fast), at compile time in the interpreter and the JIT, and on
# wasm32-wasi when wasmtime is present. A class of the sealed interface in another module is refused.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases=$root/tests/cases/sealed-when
out=$root/build/sealed-when
rm -rf "${out:?}"
mkdir -p "$out"
fail() { echo "sealed-when: $*" >&2; exit 1; }

# The IR: three type tests for four arms, and no panic for that `when`.
tests() { grep -c 'call i1 @abla_object_is' "$1" || true; }
globals() { grep -c "^@abla.when.$2" "$1" || true; }
for name in ir-sealed ir-base ir-bool; do
    "$compiler" --emit-llvm "$cases/$name.ab" > "$out/$name.ll" 2> "$out/$name.ll.err" || {
        cat "$out/$name.ll.err" >&2; fail "--emit-llvm $name.ab failed"
    }
done
added=$(( $(tests "$out/ir-sealed.ll") - $(tests "$out/ir-base.ll") ))
[[ $added == 3 ]] || fail "a four-arm sealed when has $added type tests, wanted 3"
[[ $(globals "$out/ir-sealed.ll" nonexhaustive) == $(globals "$out/ir-base.ll" nonexhaustive) ]] ||
    fail "the sealed when added a non-exhaustive panic"
for name in ir-base ir-bool; do
    [[ $(globals "$out/$name.ll" nonexhaustive) == 1 ]] || fail "$name.ll has $(globals "$out/$name.ll" nonexhaustive) non-exhaustive messages, wanted 1"
    [[ $(globals "$out/$name.ll" error) == 0 ]] || fail "$name.ll still has a message global per site"
done

# The same answers everywhere. main exits 0 when the run-time score equals the compile-time one.
expected=$("$compiler" run "$cases/main.ab" 2> "$out/run.err") || { cat "$out/run.err" >&2; fail "ablac run failed"; }
[[ $expected =~ ^([0-9]+)\ ([0-9]+)$ && ${BASH_REMATCH[1]} == "${BASH_REMATCH[2]}" ]] || fail "ablac run printed '$expected'"
for evaluator in interp jit; do
    for mode in release fast; do
        flags=(--no-cache)
        [[ $mode == fast ]] && flags+=(--fast)
        program=$out/main-$evaluator-$mode
        ABLA_COMPILE_EVAL=$evaluator "$compiler" build "$cases/main.ab" -o "$program" "${flags[@]}" > "$program.log" 2>&1 ||
            { cat "$program.log" >&2; fail "$evaluator $mode build failed"; }
        result=$("$root/tools/run-limited.sh" "$program") || fail "$evaluator $mode: exit $? ($result)"
        [[ $result == "$expected" ]] || fail "$evaluator $mode printed '$result', wanted '$expected'"
    done
done
if command -v wasmtime > /dev/null; then
    "$compiler" build "$cases/main.ab" --target wasm32-wasi -o "$out/main.wasm" --no-cache > "$out/wasm.log" 2>&1 ||
        { cat "$out/wasm.log" >&2; fail "wasm32-wasi build failed"; }
    result=$(wasmtime "$out/main.wasm") || fail "wasm32-wasi: exit $? ($result)"
    [[ $result == "$expected" ]] || fail "wasm32-wasi printed '$result', wanted '$expected'"
    wasm="native, compile time and wasm32-wasi"
else
    wasm="native and compile time (no wasmtime here)"
fi

if "$compiler" build "$cases/foreign.ab" -o "$out/foreign" --no-cache > "$out/foreign.out" 2>&1; then
    fail "a class of the sealed interface in another module compiled"
fi
grep -F 'interface.sealed-foreign:Shape:Hexagon' "$out/foreign.out" > /dev/null ||
    { cat "$out/foreign.out" >&2; fail "foreign.ab was not refused with interface.sealed-foreign"; }
echo "ok   sealed when: no test on the last arm, one shared panic message, the same score $wasm"
