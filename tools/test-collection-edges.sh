#!/usr/bin/env bash
# Collection and control-flow edge cases, table driven (tests/cases/collection-edges/cases.ab): array truncate, takeAt,
# clear and append at the boundaries, nested and nullable elements, maps with many deletes and re-inserts, nullable
# chains, when over sealed types, ints, strings and bools, closures capturing loop variables, nested loops with break
# and continue, empty ranges, compound assignment. Every case runs as ordinary code and under `#` (the interpreter and
# ABLA_COMPILE_EVAL=jit); the two must agree and print exactly the recorded cases.expected, as a fast build. A
# checksum per case line must be the same natively and as a release and a development WebAssembly
# module (needs node, else that part is skipped). An index, takeAt, truncate or filledArray out of range panics with
# status 101 and its message at run time and is E_EVAL_OUT_OF_BOUNDS under `#`. A `defer` that assigns a captured local
# is not in the table: the interpreter does not run it yet (reported to ablac-9e).
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
cases=tests/cases/collection-edges
out=build/collection-edges
rm -rf "$out"
mkdir -p "$out"

for variant in fast jit; do   # no native release build: the release WebAssembly module below covers release code generation (kept short)
    flags=(--fast)
    eval_tier=interp
    case $variant in
        jit) eval_tier=jit ;;
        release) flags=() ;;
    esac
    ABLA_COMPILE_EVAL=$eval_tier "$compiler" build "$cases/main.ab" -o "$out/main-$variant" ${flags[@]+"${flags[@]}"} --no-cache
    set +e
    "$out/main-$variant" > "$out/main-$variant.txt" 2>&1
    status=$?
    set -e
    [[ $status -eq 0 ]] || { echo "collection edges ($variant): run time and compile time differ:" >&2; grep -a -v '^LIVE' "$out/main-$variant.txt" | head -20 >&2; exit 1; }
    if ! cmp -s "$cases/cases.expected" "$out/main-$variant.txt"; then
        echo "collection edges ($variant) differs from cases.expected:" >&2
        diff "$cases/cases.expected" "$out/main-$variant.txt" | head -20 >&2
        exit 1
    fi
done
sed '1s/.*/mutated/' "$cases/cases.expected" > "$out/mutated.expected"
! cmp -s "$out/mutated.expected" "$out/main-fast.txt" || { echo "collection edges: the negative control matched" >&2; exit 1; }

# Out of range: the panic and its message, and the compile-time error in both tiers.
oob() { # $1 = statements ending in an int expression (over a = [1, 2, 3] and e = []), $2 = run time message
    printf 'import "abla/io"\nimport "abla/array"\n@noinline fun idI(x: int): int = x\nfun calc(): int {\n    val a = [idI(1), 2, 3]\n    val e: array<int> = []\n    %s\n}\nfun main: int {\n    println("${calc()}")\n    0\n}\n' "$1" > "$out/oob.ab"
    "$compiler" build "$out/oob.ab" -o "$out/oob" --fast --no-cache
    set +e
    "$out/oob" > "$out/oob.txt" 2>&1
    status=$?
    set -e
    [[ $status -eq 101 ]] && grep -Fq "$2" "$out/oob.txt" || { echo "collection edges: '$1' did not panic with '$2' (status $status):" >&2; cat "$out/oob.txt" >&2; exit 1; }
    sed 's/println("${calc()}")/println("${#calc()}")/' "$out/oob.ab" > "$out/oob-ct.ab"
    for tier in interp jit; do
        set +e
        ABLA_COMPILE_EVAL=$tier "$compiler" build "$out/oob-ct.ab" -o "$out/oob-ct" --fast --no-cache > "$out/oob-ct.log" 2>&1
        status=$?
        set -e
        [[ $status -ne 0 ]] && grep -Fq 'E_EVAL_OUT_OF_BOUNDS' "$out/oob-ct.log" || { echo "collection edges: '$1' under # ($tier) is not E_EVAL_OUT_OF_BOUNDS:" >&2; cat "$out/oob-ct.log" >&2; exit 1; }
    done
}
oob 'a[idI(3)]' 'index 3 out of bounds for array of size 3'
oob 'a[idI(-1)]' 'index -1 out of bounds for array of size 3'
oob 'e[idI(0)] = 1; 0' 'index 0 out of bounds for array of size 0'
oob 'a.truncate(idI(-1)); 0' 'truncate to a negative size (-1)'
oob 'filledArray(idI(-2), 0).size' 'filledArray with a negative size (-2)'
oob 'a.takeAt(idI(3))' 'index 3 out of bounds for array of size 3'
oob 'e.removeLast()' 'index -1 out of bounds for array of size 0'

node=${COLLECTION_EDGES_NODE:-$(command -v node || true)}
if [[ -z $node ]]; then
    echo "collection edges: native tables agree with their records; the WebAssembly part is skipped (no node)"
    exit 0
fi
"$compiler" build "$cases/wasm-native.ab" -o "$out/wasm-native" --fast --no-cache
"$out/wasm-native" > "$out/wasm-native.txt"
"$compiler" build "$cases/build.ab" -o "$out/wasm-driver" --no-cache
"$out/wasm-driver"
for module in collection collection-dev; do
    "$node" "$cases/run.mjs" "$out/$module.wasm" > "$out/$module.txt"
    if ! cmp -s "$out/wasm-native.txt" "$out/$module.txt"; then
        echo "collection edges: the $module WebAssembly module differs from the native checksums:" >&2
        diff "$out/wasm-native.txt" "$out/$module.txt" | head -20 >&2
        exit 1
    fi
done
echo "collection edges: $(grep -c . "$cases/cases.expected") cases agree at run time, under # (interpreter and JIT) and in a fast build; out-of-range panics checked; checksums match in WebAssembly"
