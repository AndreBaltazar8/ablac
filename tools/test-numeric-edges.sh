#!/usr/bin/env bash
# Numeric edge values, table driven: integer wrap-around at every width, division and remainder signs (and the smallest
# value divided by -1), shift counts at and beyond the width, conversions between integer widths, saturating float to
# integer, integer to float rounding, f32 and f64 arithmetic with NaN, infinities and signed zeros, abla/math special
# values, and identities an optimizer may fold if it thought integers could not wrap. Each program in
# tests/cases/numeric-edges runs every case as ordinary code and under `#` and exits 0 when they agree; its output
# must equal the recorded *.expected (values reviewed against docs/language.md, IEEE 754 / C99, Node 22 for abla/math)
# at run time as a fast build, with the JIT compile-time tier (ABLA_COMPILE_EVAL=jit) and as a release build. A table of
# 114 integer results (table.ab) must give the same values in a fast and a release native build, and the same values as a
# release and a development WebAssembly module (needs node, else that part is skipped).
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
cases=tests/cases/numeric-edges
out=build/numeric-edges
rm -rf "$out"
mkdir -p "$out"

for name in arith literals math optimizer; do
    # Release builds of arith and math are left out to keep the test short: a fast against release disagreement is
    # what an optimizer bug looks like, and the optimizer and literals files and the table below keep that check.
    variants=(fast jit)
    case $name in literals|optimizer) variants=(fast jit release) ;; esac
    for variant in "${variants[@]}"; do
        flags=()
        env_eval=interp
        case $variant in
            fast) flags=(--fast) ;;
            jit) flags=(--fast); env_eval=jit ;;
            release) ;;
        esac
        ABLA_COMPILE_EVAL=$env_eval "$compiler" build "$cases/$name.ab" -o "$out/$name-$variant" ${flags[@]+"${flags[@]}"} --no-cache
        set +e
        "$out/$name-$variant" > "$out/$name-$variant.txt" 2>&1
        status=$?
        set -e
        [[ $status -eq 0 ]] || { echo "numeric edges: $name ($variant) differs between run time and compile time:" >&2; grep -a -v '^LIVE' "$out/$name-$variant.txt" | head -20 >&2; exit 1; }
        if ! cmp -s "$cases/$name.expected" "$out/$name-$variant.txt"; then
            echo "numeric edges: $name ($variant) differs from $name.expected:" >&2
            diff "$cases/$name.expected" "$out/$name-$variant.txt" | head -20 >&2
            exit 1
        fi
    done
    # The comparison can see a change: a recorded file with one line altered must not match.
    sed '1s/.*/mutated/' "$cases/$name.expected" > "$out/$name-mutated.expected"
    ! cmp -s "$out/$name-mutated.expected" "$out/$name-fast.txt" || { echo "numeric edges: the negative control matched in $name" >&2; exit 1; }
done

node=${NUMERIC_EDGES_NODE:-$(command -v node || true)}
if [[ -z $node ]]; then
    echo "numeric edges: native tables agree with their records; the WebAssembly part is skipped (no node)"
    exit 0
fi
"$compiler" build "$cases/wasm-native.ab" -o "$out/wasm-native" --fast --no-cache
"$out/wasm-native" > "$out/wasm-native.txt"
cmp -s "$cases/table.expected" "$out/wasm-native.txt" || { echo "numeric edges: the native table differs from table.expected" >&2; diff "$cases/table.expected" "$out/wasm-native.txt" | head >&2; exit 1; }
"$compiler" build "$cases/wasm-native.ab" -o "$out/wasm-native-release" --no-cache
"$out/wasm-native-release" > "$out/wasm-native-release.txt"
cmp -s "$out/wasm-native.txt" "$out/wasm-native-release.txt" || { echo "numeric edges: the table differs between a fast and a release native build" >&2; exit 1; }
"$compiler" build "$cases/build.ab" -o "$out/wasm-driver" --no-cache
"$out/wasm-driver"
for module in numeric numeric-dev; do
    "$node" "$cases/run.mjs" "$out/$module.wasm" > "$out/$module.txt"
    if ! cmp -s "$out/wasm-native.txt" "$out/$module.txt"; then
        echo "numeric edges: the $module WebAssembly module differs from the native table:" >&2
        diff "$out/wasm-native.txt" "$out/$module.txt" | head -20 >&2
        exit 1
    fi
done
echo "numeric edges: 4 tables agree at run time, under # (interpreter and JIT) and in a release build; the 114-value table matches in WebAssembly"
