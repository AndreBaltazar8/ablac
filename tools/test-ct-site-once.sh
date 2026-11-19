#!/usr/bin/env bash
# A `#` site runs once per build (docs/compile-time.md), also when compile-time code meets it again
# (tests/cases/ct-site-once): forward.ab reads a global a site initialized, body.ab calls a function whose body is a
# site. The code read the global or called the function anew and ran the site's code a second time, in both tiers:
# the game client's screenshot site ran the client twice and the second run captured a black frame (#1022).
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "$0")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
out="$project_root/build/ct-site-once"
rm -rf "$out"; mkdir -p "$out"
cd "$project_root/tests/cases/ct-site-once"
fail() { echo "ct site once: $*" >&2; exit 1; }
for program in forward body; do
    tag=a; [[ $program == body ]] && tag=f
    for mode in interp jit; do
        ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build $program.ab -o "$out/$program-$mode" \
            --fast --no-cache > "$out/$program-$mode.log" 2>&1 ||
            { cat "$out/$program-$mode.log" >&2; fail "the $mode build of $program.ab failed"; }
        runs=$(grep -c "^bump $tag" "$out/$program-$mode.log" || true)
        [[ $runs == 1 ]] || { grep -E '^bump|ct-jit' "$out/$program-$mode.log" >&2; fail "$program.ab, $mode: the site ran $runs times"; }
        got=$("$out/$program-$mode")
        [[ $got == "1 2" ]] || fail "$program.ab, $mode: '$got', expected '1 2'"
    done
    # In both tiers the sites' code runs natively where it can (jit), never in the evaluator for this.
    if grep 'interpreted at' "$out/$program-jit.log" >&2; then fail "$program.ab: a site was interpreted"; fi
done
# The effects' order (docs/compile-time.md): a site's code runs when the build first needs its value, `a`'s before
# `c`'s, whose code reads `a`, as `c` initializes after `a` at run time.
for mode in interp jit; do
    order=$(grep -E '^(bump|twice)' "$out/forward-$mode.log" | tr '\n' '|')
    [[ $order == "bump a 1|twice|" ]] || fail "forward.ab, $mode: effects in the order '$order', expected 'bump a 1|twice|'"
done
echo "ct site once: a site runs once when compile-time code meets it again, natively too, in the build's order"
