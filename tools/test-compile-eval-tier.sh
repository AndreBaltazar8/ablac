#!/usr/bin/env bash
# The compile-time tier policy (docs/compile-time.md#native-evaluation): with ABLA_COMPILE_EVAL
# unset or empty the tier is `auto`, which runs each site natively when the native tier can take
# it and in the evaluator otherwise, chosen before the site runs; `interp` and `jit` stay
# explicit overrides.
#   - heavy.ab: work past a lowered step limit is native by default and gives the run-time
#     answer; under `interp` the same site stops with E_EVAL_STEP_LIMIT;
#   - bounded.ab, recursive.ab: under auto a pass whose sites reach no loop, lambda or recursion gets no
#     native generation (the interpreter runs them), one with recursion does; jit takes both;
#   - effects/: a site the native tier takes and one it refuses each append one line to a file:
#     each file holds its line once (no site runs twice to choose), the trace says which ran
#     natively and why the other did not.
set -euo pipefail

compiler=${1:-build/ablac.bin}
[[ $compiler == /* ]] || compiler=$PWD/$compiler
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/compile-eval-tier"
output="$project_root/build/compile-eval-tier"
rm -rf "$output"
mkdir -p "$output"
fail() { echo "compile-eval-tier: $*" >&2; exit 1; }

build() { # tag source [env...]: builds into $output/<tag>, the trace in <tag>.trace; returns the build's status
    local tag=$1 source=$2
    shift 2
    env "$@" ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build "$source" -o "$output/$tag" --no-cache \
        >"$output/$tag.out" 2>"$output/$tag.trace"
}

runs() { # tag: the program's exit status
    local status=0
    "$output/$1" || status=$?
    echo "$status"
}

# 1. Heavy work: the default (unset, empty, auto) and jit run it natively; interp stops at the step limit.
for tier in unset empty auto jit; do
    case $tier in
        unset) settings=(-u ABLA_COMPILE_EVAL) ;;
        empty) settings=(ABLA_COMPILE_EVAL=) ;;
        *) settings=(ABLA_COMPILE_EVAL=$tier) ;;
    esac
    build "heavy-$tier" "$cases/heavy.ab" "${settings[@]}" ABLA_EVAL_STEP_LIMIT=100000 ||
        { cat "$output/heavy-$tier.trace" >&2; fail "heavy.ab under $tier did not build"; }
    [[ $(runs "heavy-$tier") == 42 ]] || fail "heavy.ab under $tier did not give the run-time answer"
    grep -q '^note\[ct-jit\]: native at' "$output/heavy-$tier.trace" ||
        { cat "$output/heavy-$tier.trace" >&2; fail "heavy.ab's site was not native under $tier"; }
done
if build heavy-interp "$cases/heavy.ab" ABLA_COMPILE_EVAL=interp ABLA_EVAL_STEP_LIMIT=100000; then
    fail "heavy.ab built under interp with a step limit of 100000"
fi
grep -q 'E_EVAL_STEP_LIMIT' "$output/heavy-interp.trace" ||
    { cat "$output/heavy-interp.trace" >&2; fail "heavy.ab under interp did not stop at the step limit"; }
! grep -q 'native at' "$output/heavy-interp.trace" || fail "a site ran natively under interp"

# 2. Effects once, on the tier chosen before the site runs.
for tier in unset interp jit; do
    work="$output/effects-$tier.work"
    mkdir -p "$work"
    cp "$cases/effects/main.ab" "$cases/effects/abla.toml" "$work/"
    case $tier in
        unset) settings=(-u ABLA_COMPILE_EVAL) ;;
        *) settings=(ABLA_COMPILE_EVAL=$tier) ;;
    esac
    (cd "$work" && build "effects-$tier" main.ab "${settings[@]}") ||
        { cat "$output/effects-$tier.trace" >&2; fail "effects under $tier did not build"; }
    [[ $(cd "$work" && runs "effects-$tier") == 42 ]] || fail "effects under $tier gave the wrong values"
    for name in native evaluated; do
        [[ $(cat "$work/build-compile-eval-tier/$name.txt") == "$name" ]] ||
            fail "effects under $tier: $name.txt holds '$(cat "$work/build-compile-eval-tier/$name.txt")', not one line"
    done
    if [[ $tier != interp ]]; then
        [[ $(grep -c '^note\[ct-jit\]: native at' "$output/effects-$tier.trace") == 1 ]] ||
            { cat "$output/effects-$tier.trace" >&2; fail "effects under $tier: not exactly one native site"; }
        grep -q '^note\[ct-jit\]: interpreted at [0-9]*: .*compilerApplyTransform' "$output/effects-$tier.trace" ||
            { cat "$output/effects-$tier.trace" >&2; fail "effects under $tier: the refused site's reason is missing"; }
    fi
done

# 3. A pass whose sites reach no loop, lambda or recursion has no native generation under auto (the
# interpreter's work for them is bounded by the code's size), but runs natively under jit; recursion
# alone (a cycle of calls, no loop) makes a pass worth one.
build bounded-auto "$cases/bounded.ab" -u ABLA_COMPILE_EVAL ||
    { cat "$output/bounded-auto.trace" >&2; fail "bounded.ab under auto did not build"; }
[[ $(runs bounded-auto) == 42 ]] || fail "bounded.ab under auto gave the wrong values"
! grep -q '^note\[ct-jit\]: \(generation\|native at\)' "$output/bounded-auto.trace" ||
    { cat "$output/bounded-auto.trace" >&2; fail "bounded.ab under auto made a native generation"; }
[[ $(grep -c '^note\[ct-jit\]: interpreted at [0-9]*: auto: no site of this pass reaches a loop' \
    "$output/bounded-auto.trace") == 2 ]] ||
    { cat "$output/bounded-auto.trace" >&2; fail "bounded.ab under auto: the two sites don't give the reason"; }
build bounded-jit "$cases/bounded.ab" ABLA_COMPILE_EVAL=jit ||
    { cat "$output/bounded-jit.trace" >&2; fail "bounded.ab under jit did not build"; }
[[ $(runs bounded-jit) == 42 ]] || fail "bounded.ab under jit gave the wrong values"
[[ $(grep -c '^note\[ct-jit\]: native at' "$output/bounded-jit.trace") == 2 ]] ||
    { cat "$output/bounded-jit.trace" >&2; fail "bounded.ab under jit: not both sites native"; }
build recursive-auto "$cases/recursive.ab" -u ABLA_COMPILE_EVAL ||
    { cat "$output/recursive-auto.trace" >&2; fail "recursive.ab under auto did not build"; }
[[ $(runs recursive-auto) == 42 ]] || fail "recursive.ab under auto gave the wrong value"
grep -q '^note\[ct-jit\]: native at' "$output/recursive-auto.trace" ||
    { cat "$output/recursive-auto.trace" >&2; fail "recursive.ab's site was not native under auto"; }

echo "compile-eval-tier: ok"
