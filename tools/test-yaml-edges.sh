#!/usr/bin/env bash
# YAML edge cases, table driven (tests/cases/yaml-edges/main.ab): 283 inputs whose parse result (or error code) is
# recorded in main.expected after checking each against the YAML 1.2 Core schema and docs/stdlib/yaml.md, plus per input
# the properties that the lossless document returns the original bytes and yamlParse's verdict, and that a value emitted
# in seven layouts parses back to itself. Every case runs as ordinary code and under `#` (the interpreter and
# ABLA_COMPILE_EVAL=jit); the two must agree and print exactly main.expected.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
cases=tests/cases/yaml-edges
out=build/yaml-edges
rm -rf "$out"
mkdir -p "$out"

for tier in interp jit; do
    ABLA_COMPILE_EVAL=$tier "$compiler" build "$cases/main.ab" -o "$out/main-$tier" --fast --no-cache
    set +e
    "$out/main-$tier" > "$out/main-$tier.txt" 2>&1
    status=$?
    set -e
    [[ $status -eq 0 ]] || { echo "yaml edges ($tier): run time and compile time differ:" >&2; grep -a '^DIFF' "$out/main-$tier.txt" | head -10 >&2; exit 1; }
    if ! cmp -s "$cases/main.expected" "$out/main-$tier.txt"; then
        echo "yaml edges ($tier) differs from main.expected:" >&2
        diff "$cases/main.expected" "$out/main-$tier.txt" | head -20 >&2
        exit 1
    fi
done
grep -a 'DIFFERS\|FAILED' "$cases/main.expected" > /dev/null && { echo "yaml edges: main.expected records a failed property" >&2; exit 1; }
sed '1s/.*/mutated/' "$cases/main.expected" > "$out/mutated.expected"
! cmp -s "$out/mutated.expected" "$out/main-interp.txt" || { echo "yaml edges: the negative control matched" >&2; exit 1; }
echo "yaml edges: $(grep -c '=>' "$cases/main.expected") inputs agree at run time and under # (interpreter and JIT); round trips and lossless text hold"
