#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/array-remove-last-test
mkdir -p "$out"
# Each positive includes a compile-time evaluation of the same checks.
for profile in fast o1 release; do
    flags=()
    if [[ $profile == fast ]]; then flags=(--fast); fi
    if [[ $profile == o1 ]]; then flags=(--o1); fi
    for name in main take resource; do
        "$compiler" build "tests/cases/array-remove-last/$name.ab" -o "$out/$name-$profile" ${flags[@]+"${flags[@]}"} --no-cache
        "$out/$name-$profile"
        ABLA_GC_STRESS=1 "$out/$name-$profile"
    done
done
for name in empty bad-index; do
    "$compiler" build "tests/cases/array-remove-last/$name.ab" -o "$out/$name" --fast --no-cache
    status=0
    "$out/$name" > "$out/$name.log" 2>&1 || status=$?
    [[ $status == 101 ]] || { cat "$out/$name.log" >&2; exit 1; }
done
grep -Fxq 'panic: index -1 out of bounds for array of size 0' "$out/empty.log"
grep -Fxq 'panic: index 3 out of bounds for array of size 3' "$out/bad-index.log"
for name in borrowed borrowed-loop borrowed-loop-last borrowed-loop-at borrowed-loop-helper; do
    if "$compiler" build "tests/cases/array-remove-last/$name.ab" -o "$out/invalid" --fast --no-cache > "$out/$name.log" 2>&1; then
        echo "$name unexpectedly allowed removing a borrowed element" >&2; exit 1
    fi
    grep -Eq 'ownership\.(borrow|mutable-borrow)' "$out/$name.log" || { cat "$out/$name.log" >&2; exit 1; }
done
if "$compiler" build tests/cases/array-remove-last/copied-element.ab -o "$out/invalid" --fast --no-cache > "$out/copied.log" 2>&1; then
    echo 'indexing unexpectedly copied an owned resource' >&2; exit 1
fi
grep -Fq 'ownership.place-move-required:local.item' "$out/copied.log"
"$compiler" build tests/cases/array-remove-last/build-wasm.ab -o "$out/build-wasm" --fast --no-cache
node tests/cases/array-remove-last/run-wasm.mjs "$out/move.wasm" "$out/move-fast.wasm"
echo 'array move-out: owned results, ordered remaining drops, close once, CT parity, bounds and borrow checks'
