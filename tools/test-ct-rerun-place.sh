#!/usr/bin/env bash
# A native failure of a site that can run again unseen is placed by rerunning it in the evaluator
# (tests/cases/ct-rerun-place): its report has the evaluator's place and path, inlined functions too. A site that
# reads the clock or the environment, or anything else outside the evaluator, isn't rerun and keeps its native place
# (the site), and so does one whose failure lies past the rerun's budget.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$project_root/build/ct-rerun-place
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-rerun-place"
fail() { echo "ct rerun place: $1" >&2; [[ -z ${2:-} ]] || cat "$2" >&2; exit 1; }
build() { # name tier
    local status=0
    ABLA_COMPILE_EVAL=$2 ABLA_COMPILE_EVAL_TRACE=1 timeout 300 "$compiler" build $1.ab -o "$out/$1-$2" --fast \
        --no-cache > "$out/$1-$2.log" 2>&1 || status=$?
    [[ $status == 1 ]] || fail "$1 $2: the compiler exited $status, not 1" "$out/$1-$2.log"
}
report() { grep -v '^note\[\|^source\[' "$1"; }

# inlined: the native report is the evaluator's, but for the place line, which says how it was found.
build inlined interp
build inlined jit
grep -q '^note\[ct-jit\]: rerun at .*inlined.ab:[0-9]*: the evaluator placed the failure$' "$out/inlined-jit.log" ||
    fail "inlined: not rerun" "$out/inlined-jit.log"
place=$(grep -o '^  --> [^ ]*' "$out/inlined-interp.log" | head -1); place=${place#  --> }
grep -q "^  --> $place (found by rerunning the site in the evaluator)\$" "$out/inlined-jit.log" ||
    fail "inlined: the native place isn't the evaluator's ($place)" "$out/inlined-jit.log"
diff <(report "$out/inlined-interp.log" | grep -v '^  --> ') <(report "$out/inlined-jit.log" | grep -v '^  --> ') \
    > "$out/inlined.diff" || fail "inlined: the reports differ outside the place" "$out/inlined.diff"
grep -q '^  = note: in `pick`' "$out/inlined-jit.log" || fail "inlined: no pick in the path" "$out/inlined-jit.log"
echo "ok   inlined: placed at $place by rerunning it, with pick and table"

# clock, environment: never rerun; the site is the place, as before.
for name in clock environment; do
    build $name jit
    grep -Eq "^note\[ct-jit\]: no rerun at .*$name.ab:[0-9]*: it reaches the (compile-time provider|compiler API) " "$out/$name-jit.log" ||
        fail "$name: rerun, or not said why not" "$out/$name-jit.log"
    grep -q "^  --> $name.ab:[0-9]*:[0-9]* (its \`#\` site: the native tier's code has no line table)\$" \
        "$out/$name-jit.log" || fail "$name: not placed at its site" "$out/$name-jit.log"
    echo "ok   $name: not rerun ($(grep -o "no rerun at .*" "$out/$name-jit.log" | sed "s/.*: it reaches //"))"
done

# budget: rerun, but the failure lies past its budget.
build budget jit
grep -q "^note\[ct-jit\]: rerun at .*budget.ab:[0-9]*: the evaluator didn't fail the same way within its budget\$" \
    "$out/budget-jit.log" || fail "budget: not said" "$out/budget-jit.log"
grep -q "^  --> budget.ab:[0-9]*:[0-9]* (its \`#\` site: the native tier's code has no line table)\$" \
    "$out/budget-jit.log" || fail "budget: not placed at its site" "$out/budget-jit.log"
echo "ok   budget: the rerun stopped short, the site stays the place"
echo "ct rerun place: native failures of sites that can run again are placed by the evaluator; the others aren't rerun"
