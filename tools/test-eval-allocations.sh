#!/usr/bin/env bash
# The interpreter's value objects, counted (ABLA_COMPILE_EVAL_TIMES=1 ends the build with `evaluator values: TOTAL kind=N ...`; eval.ab's bootstrapEvalMake):
# tests/cases/eval-allocations/main.ab, evaluated by the interpreter, constructs no more than the budget in tests/cases/eval-allocations/budget.txt (a total, and a
# line `kind N` for a kind that has a limit of its own), and prints the same result. A change that brings the allocations back (a value that was shared and is built
# again) fails; a change that saves some lowers the budget in the same commit (the check says how far below it is).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
cases=tests/cases/eval-allocations
out=build/eval-allocations
rm -rf "$out"
mkdir -p "$out"
ABLA_COMPILE_EVAL=interp ABLA_COMPILE_EVAL_TIMES=1 "$compiler" build "$cases/main.ab" -o "$out/main" --fast --no-cache > "$out/build.out" 2> "$out/build.err" ||
    { cat "$out/build.err" >&2; echo "eval allocations: the build failed" >&2; exit 1; }
line=$(grep '^  evaluator values: ' "$out/build.err" | tail -1 || true)
[[ -n $line ]] || { cat "$out/build.err" >&2; echo "eval allocations: no count in the build's listing" >&2; exit 1; }
total=$(awk '{print $3}' <<<"$line")
echo "eval allocations: $line"
[[ $("$out/main") == "$(cat "$cases/expected.txt")" ]] || { echo "eval allocations: the program's output differs from $cases/expected.txt" >&2; exit 1; }
status=0
limit=$(awk '$1 == "total" {print $2}' "$cases/budget.txt")
if ((total > limit)); then echo "eval allocations: $total values, over the budget of $limit" >&2; status=1; fi
if ((total * 100 < limit * 90)); then echo "eval allocations: $total values, more than 10% under the budget of $limit: lower it in $cases/budget.txt" >&2; status=1; fi
while read -r kind max; do
    [[ $kind == total || -z $kind ]] && continue
    have=$(tr ' ' '\n' <<<"$line" | awk -F= -v k="$kind" '$1 == k {print $2}')
    have=${have:-0}
    if ((have > max)); then echo "eval allocations: $kind: $have values, over its limit of $max" >&2; status=1; fi
done < "$cases/budget.txt"
[[ $status == 0 ]] || exit 1
echo "eval allocations: $total values, within the budget of $limit"
