#!/usr/bin/env bash
# abla/regex refusals and limits, table driven (tests/cases/regex-edges/main.ab): every refusal docs/stdlib/regex.md lists
# (backreferences and octal escapes, lookaround, named groups, inline flags, unknown escapes, \b in a class, nothing to
# repeat, stacked quantifiers, bad ranges and intervals, unterminated groups and classes, invalid UTF-8) with its message
# and offset, what is accepted next to each, and the limits at their boundaries (500 groups, 200 nesting levels, repeat
# counts of 1000, 100000 instructions, regexCompileWithin). The first table also runs under `#` (interpreter and
# ABLA_COMPILE_EVAL=jit) and must agree; the whole output must equal main.expected. The random patterns and the Python
# corpus are tools/test-regex.sh and tools/fuzz/run --regex; this fills in what they do not generate.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
cases=tests/cases/regex-edges
out=build/regex-edges
rm -rf "$out"
mkdir -p "$out"

for tier in interp jit; do
    ABLA_COMPILE_EVAL=$tier "$compiler" build "$cases/main.ab" -o "$out/main-$tier" --fast --no-cache
    set +e
    "$out/main-$tier" > "$out/main-$tier.txt" 2>&1
    status=$?
    set -e
    [[ $status -eq 0 ]] || { echo "regex edges ($tier): run time and compile time differ:" >&2; grep -a '^DIFF' "$out/main-$tier.txt" | head -10 >&2; exit 1; }
    if ! cmp -s "$cases/main.expected" "$out/main-$tier.txt"; then
        echo "regex edges ($tier) differs from main.expected:" >&2
        diff "$cases/main.expected" "$out/main-$tier.txt" | head -20 >&2
        exit 1
    fi
done
sed '1s/.*/mutated/' "$cases/main.expected" > "$out/mutated.expected"
! cmp -s "$out/mutated.expected" "$out/main-interp.txt" || { echo "regex edges: the negative control matched" >&2; exit 1; }
echo "regex edges: $(grep -a -c '^LIVE' "$cases/main.expected") refusal and syntax cases (run time and under #, both tiers) and $(grep -a -c '^LIMIT' "$cases/main.expected") limit cases agree with main.expected"

for mode in fast release; do
    options=()
    [[ $mode == release ]] || options+=(--fast)
    "$compiler" build tests/cases/regex/within.ab -o "$out/within-$mode" --no-cache "${options[@]}"
    "$out/within-$mode" | grep -Fx 'bounded regex: ok' >/dev/null
done

# Sorted, merged class ranges and the binary search against a linear scan of the ranges as written (#1139, R5-1).
"$compiler" build tests/cases/regex/class-diff.ab -o "$out/class-diff" --no-cache
"$out/class-diff" | tee "$out/class-diff.txt" | grep -E '^class-diff: 2400 classes, [0-9]+ \(class, code point\) pairs, 0 differences$' >/dev/null ||
    { echo "regex edges: class differential failed:" >&2; head -12 "$out/class-diff.txt" >&2; exit 1; }
cat "$out/class-diff.txt"
