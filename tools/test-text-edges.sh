#!/usr/bin/env bash
# Text edge cases, table driven (tests/cases/text-edges/cases.ab): slice, index and size at UTF-8 boundaries, byte-order
# comparison (bytes above 127 sort after ASCII), search, split, join, replace and trim on empty and multi-byte input,
# ASCII-only case mapping, repeat and padding, code points, validity, string map keys, sorting. Every case runs as ordinary
# code and under `#` (the interpreter and ABLA_COMPILE_EVAL=jit); the two must agree and print exactly the recorded
# text.expected (values reviewed against docs/language.md and docs/stdlib/text.md). Release is built for the same table
# only once (a fast against release disagreement is what an optimizer bug looks like). A checksum per case line must be the
# same natively and as a release and a development WebAssembly module (needs node, else that part is skipped). Out of
# bounds indexes and slices panic with status 101 and their message at run time and are E_EVAL_OUT_OF_BOUNDS under `#`.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
cases=tests/cases/text-edges
out=build/text-edges
rm -rf "$out"
mkdir -p "$out"

for variant in fast jit release; do
    flags=(--fast)
    eval_tier=interp
    case $variant in
        jit) eval_tier=jit ;;
        release) flags=() ;;
    esac
    ABLA_COMPILE_EVAL=$eval_tier "$compiler" build "$cases/text.ab" -o "$out/text-$variant" ${flags[@]+"${flags[@]}"} --no-cache
    set +e
    "$out/text-$variant" > "$out/text-$variant.txt" 2>&1
    status=$?
    set -e
    [[ $status -eq 0 ]] || { echo "text edges ($variant): run time and compile time differ:" >&2; grep -a -v '^LIVE' "$out/text-$variant.txt" | head -20 >&2; exit 1; }
    if ! cmp -s "$cases/text.expected" "$out/text-$variant.txt"; then
        echo "text edges ($variant) differs from text.expected:" >&2
        diff "$cases/text.expected" "$out/text-$variant.txt" | head -20 >&2
        exit 1
    fi
done
sed '1s/.*/mutated/' "$cases/text.expected" > "$out/mutated.expected"
! cmp -s "$out/mutated.expected" "$out/text-fast.txt" || { echo "text edges: the negative control matched" >&2; exit 1; }

# Out of bounds: the panic and its message, and the compile-time error in both tiers.
oob() { # $1 = expression over s = "héllo" (6 bytes), $2 = run time message
    printf 'import "abla/io"\n@noinline fun idI(x: int): int = x\nfun calc(): int {\n    val s = "h\\u00e9llo"\n    %s\n}\nfun main: int {\n    println("${calc()}")\n    0\n}\n' "$1" > "$out/oob.ab"
    "$compiler" build "$out/oob.ab" -o "$out/oob" --fast --no-cache
    set +e
    "$out/oob" > "$out/oob.txt" 2>&1
    status=$?
    set -e
    [[ $status -eq 101 ]] && grep -Fq "$2" "$out/oob.txt" || { echo "text edges: '$1' did not panic with '$2' (status $status):" >&2; cat "$out/oob.txt" >&2; exit 1; }
    sed 's/println("${calc()}")/println("${#calc()}")/' "$out/oob.ab" > "$out/oob-ct.ab"
    for tier in interp jit; do
        set +e
        ABLA_COMPILE_EVAL=$tier "$compiler" build "$out/oob-ct.ab" -o "$out/oob-ct" --fast --no-cache > "$out/oob-ct.log" 2>&1
        status=$?
        set -e
        [[ $status -ne 0 ]] && grep -Fq 'E_EVAL_OUT_OF_BOUNDS' "$out/oob-ct.log" || { echo "text edges: '$1' under # ($tier) is not E_EVAL_OUT_OF_BOUNDS:" >&2; cat "$out/oob-ct.log" >&2; exit 1; }
    done
}
oob 's[idI(-1)]' 'index -1 out of bounds for string of size 6'
oob 's[idI(100)]' 'index 100 out of bounds for string of size 6'
oob 's.slice(idI(3), 2).size' 'slice 3..2 out of bounds for string of size 6'
oob 's.slice(idI(-1), 2).size' 'slice -1..2 out of bounds for string of size 6'
oob 's.slice(0, idI(7)).size' 'slice 0..7 out of bounds for string of size 6'

node=${TEXT_EDGES_NODE:-$(command -v node || true)}
if [[ -z $node ]]; then
    echo "text edges: native tables agree with their records; the WebAssembly part is skipped (no node)"
    exit 0
fi
"$compiler" build "$cases/wasm-native.ab" -o "$out/wasm-native" --fast --no-cache
"$out/wasm-native" > "$out/wasm-native.txt"
"$compiler" build "$cases/build.ab" -o "$out/wasm-driver" --no-cache
"$out/wasm-driver"
for module in text text-dev; do
    "$node" "$cases/run.mjs" "$out/$module.wasm" > "$out/$module.txt"
    if ! cmp -s "$out/wasm-native.txt" "$out/$module.txt"; then
        echo "text edges: the $module WebAssembly module differs from the native checksums:" >&2
        diff "$out/wasm-native.txt" "$out/$module.txt" | head -20 >&2
        exit 1
    fi
done
echo "text edges: $(grep -c . "$cases/text.expected") cases agree at run time, under # (interpreter and JIT) and in a release build; out-of-bounds panics checked; checksums match in WebAssembly"
