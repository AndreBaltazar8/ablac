#!/usr/bin/env bash
# A failing `#` site is reported the same way in both tiers (tests/cases/ct-site-errors): the same error code and
# text, then where it failed, then the site it came from ("= note: in `#table()` at file:line:col"), and a last line
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
for case in bounds division panic exit deep late denied; do
    for mode in interp jit; do
        log=$out/$case-$mode.log
        status=0
        ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TIME_LIMIT=1 timeout 120 "$compiler" build $case.ab \
            -o "$out/$case-$mode" --fast --no-cache > "$log" 2>&1 || status=$?
        [[ $status == 1 ]] || fail "$case $mode: the compiler exited $status, not 1" "$log"
        [[ $(grep -c '^error\[' "$log") == 1 ]] || fail "$case $mode: not one error" "$log"
        grep -q '^  --> ' "$log" || fail "$case $mode: no place" "$log"
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
    grep -q "^  --> $site_place (its \`#\` site: the native tier's code has no line table)$" "$jit" ||
        fail "$case jit: the place isn't the site, said so" "$jit"
    # The interpreter's place is inside the code the site runs, not the site.
    place=$(grep -o '^  --> [^ ]*' "$interp" | head -1); place=${place#  --> }
    [[ $place == $case.ab:* && $place != "$site_place" ]] || fail "$case interp: the place is '$place'" "$interp"
    grep -q '^compile-time evaluation failed: 1 error(s)$' "$jit" || fail "$case: the last line" "$jit"
    echo "ok   $case: $(grep '^error\[' "$jit" | cut -c1-70); interp at $place, site $site_place"
done
echo "ct site errors: a failing site's report has the same code and text in both tiers, the place where it failed and its site"
