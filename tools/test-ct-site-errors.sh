#!/usr/bin/env bash
# A failing `#` site is reported the same way in both tiers (tests/cases/ct-site-errors): the same error code and
# text, then where it failed, then the user functions it was in, innermost first (native code names the ones it
# didn't inline; the cases are @noinline), then the site it came from ("= note: in `#table()` at file:line:col"), and a last line
# that says compile-time evaluation failed. The one part that differs is the place line (`-->`): the interpreter
# knows the expression it was evaluating; native code has no line table, so its place is the site, and says so.
# A capability the module didn't grant is refused before anything runs, the same in both.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out=$project_root/build/ct-site-errors
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-site-errors"
fail() { echo "ct site errors: $1" >&2; [[ -z ${2:-} ]] || cat "$2" >&2; exit 1; }
# The report without the tier's place: record lines and `-->` lines out, the trace's notes out.
common() { grep -v '^source\[\|^  --> \|^note\[' "$1"; }
declare -A expected_path=([bounds]="pick table" [division]="ratio table" [panic]=check [exit]=leave [deep]=down [late]=waitPastDeadline)
for case in bounds division panic exit deep late denied; do
    # Only the deadline fixture should race the clock. In particular, a loaded
    # interpreter must reach deep's stack guard before any unrelated timer.
    time_limit=0
    # This case must end at its deadline even with few interpreter steps left;
    # a clock-polling loop would hit E_EVAL_STEP_LIMIT first on a fast tier.
    extra_env=()
    if [[ $case == late ]]; then
        time_limit=1
        extra_env+=(ABLA_EVAL_STEP_LIMIT=100000)
    fi
    for mode in interp jit; do
        log=$out/$case-$mode.log
        status=0
        env "${extra_env[@]}" ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TIME_LIMIT=$time_limit timeout 120 "$compiler" build $case.ab \
            -o "$out/$case-$mode" --fast --no-cache > "$log" 2>&1 || status=$?
        [[ $status == 1 ]] || fail "$case $mode: the compiler exited $status, not 1" "$log"
        [[ $(grep -c '^error\[' "$log") == 1 ]] || fail "$case $mode: not one error" "$log"
        grep -q '^  --> ' "$log" || fail "$case $mode: no place" "$log"
        if [[ $case == late ]]; then
            grep -q '^error\[E_CT_TIME_LIMIT\]' "$log" || fail "$case $mode: not its deadline" "$log"
        elif [[ $case == deep ]]; then
            grep -q '^error\[E_EVAL_STACK_DEPTH\]' "$log" || fail "$case $mode: not its stack guard" "$log"
        fi
    done
    interp=$out/$case-interp.log jit=$out/$case-jit.log
    diff <(common "$interp") <(common "$jit") > "$out/$case.diff" ||
        fail "$case: the tiers' reports differ outside the place line" "$out/$case.diff"
    if [[ $case == denied ]]; then
        grep -q '^error\[E_SEMANTIC\]: compile.effect-denied:environment' "$jit" || fail "denied: not refused" "$jit"
        continue
    fi
    site=$(grep -o "^  = note: in \`#[^\`]*\` at $case.ab:[0-9]*:[0-9]*$" "$jit") ||
        fail "$case: no note naming the site" "$jit"
    site_place=${site##* at }
    # The interpreter's place is inside the code the site runs, not the site.
    place=$(grep -o '^  --> [^ ]*' "$interp" | head -1); place=${place#  --> }
    [[ $place == $case.ab:* && $place != "$site_place" ]] || fail "$case interp: the place is '$place'" "$interp"
    # Native code's place is the site, said so; or, for a site that can run again unseen (tools/test-ct-rerun-place.sh),
    # the interpreter's, found by rerunning it there.
    grep -q "^  --> $site_place (its \`#\` site: the native tier's code has no line table)$" "$jit" ||
        grep -q "^  --> $place (found by rerunning the site in the evaluator)$" "$jit" ||
        fail "$case jit: the place is neither the site nor the evaluator's" "$jit"
    grep -q '^compile-time evaluation failed: 1 error(s)$' "$jit" || fail "$case: the last line" "$jit"
    # The functions it was in, innermost first, the same in both tiers (the common report above): a run of
    # recursive calls is named once, and the standard library's functions not at all.
    path=$({ grep -o "^  = note: in \`[^\`]*\`, declared at $case.ab" "$jit" || true; } | sed -E "s/^  = note: in \`([^\`]*)\`.*/\1/" | tr "\\n" " ")
    [[ $path == "${expected_path[$case]} " ]] || fail "$case: the path is '$path', not '${expected_path[$case]}'" "$jit"
    echo "ok   $case: $(grep '^error\[' "$jit" | cut -c1-70); interp at $place, site $site_place"
done
echo "ct site errors: a failing site's report has the same code and text in both tiers, the place where it failed and its site"
