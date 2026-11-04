#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out="$root/build/named-overloads-test"
mkdir -p "$out"
expect42() {
    local status=0
    "$@" || status=$?
    [[ $status == 42 ]] || { echo "named overloads: expected42, got$status: $*" >&2; exit 1; }
}
for profile in fast release; do
    flags=()
    if [[ $profile == fast ]]; then flags+=(--fast); fi
    for case in main order-affine concrete-receivers inferred-methods; do
        "$compiler" build "tests/cases/named-overloads/$case.ab" -o "$out/$case-$profile" --no-cache ${flags[@]+"${flags[@]}"}
        expect42 "$out/$case-$profile"
    done
done
for mode in interp jit; do
    for case in staged edits; do
        ABLA_COMPILE_EVAL=$mode "$compiler" build "tests/cases/named-overloads/$case.ab" --fast --no-cache -o "$out/$case-$mode"
        expect42 "$out/$case-$mode"
    done
done
cat > "$out/ambiguous.ab" <<'ABLA'
class A {}
class B {}
fun f(a: A?, n: int = 0): int = n
fun f(b: B?, n: int = 0): int = n
fun main: int = f(null, n = 1)
ABLA
cat > "$out/unknown-generic.ab" <<'ABLA'
class A {}
fun f(a: A, n: int = 0): int = 1
fun f(a: any, n: int = 0): int = 2
fun <T> check(value: T): int = f(value, n = 1)
fun main: int = check(A())
ABLA
for case in ambiguous unknown-generic; do
    if "$compiler" build "$out/$case.ab" --fast --no-cache -o "$out/rejected" > "$out/$case.log" 2>&1; then
        echo "named overloads: $case unexpectedly built" >&2; exit 1
    fi
    grep -q 'error\[E_NAMED_ARGUMENT_TARGET\]' "$out/$case.log"
done
echo 'named overloads: positional typing, per-candidate names/defaults, generic callers, shadowing, affine/order/staged checks and real ambiguity passed'
