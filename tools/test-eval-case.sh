#!/usr/bin/env bash
# The evaluator picks the case for an expression by its kind (eval.ab, bootstrapEvalCase): a table for the kinds that decide it alone, the chain of tests for the rest.
# tests/cases/eval-case/main.ab asks bootstrapEvalCaseTableAgrees whether the table gives, for each of its kinds, what the chain gives; a kind added to one and
# not the other, or put in the table ahead of a test of the chain that would have caught it, fails here. (The compile-time parity and ct-* suites run the evaluator on
# real programs.)
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/eval-case
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/eval-case/main.ab -o "$out/main" --fast --no-cache > "$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; echo "eval case: the build failed" >&2; exit 1; }
"$out/main" | tee "$out/run.txt"
grep -q 'agrees with the chain' "$out/run.txt"
