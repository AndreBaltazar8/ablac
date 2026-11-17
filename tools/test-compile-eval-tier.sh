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
#     natively and why the other did not;
#   - trial.ab, printing.ab: under auto a site that can act on nothing outside the interpreter
#     runs there first within a step budget (a trial), and needs no generation if it finishes;
#     one that prints gets no trial.
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
# Literal subparser registrations (abla/json's) never run, so they are no sites: a program with no other `#`
# prepares no pass (no write analysis, no call targets kept), which held the compiler's self-build ~45 MB over
# interp (tools/test-compiler-memory-peak.sh).
for tier in unset jit; do
    case $tier in
        unset) settings=(-u ABLA_COMPILE_EVAL) ;;
        *) settings=(ABLA_COMPILE_EVAL=$tier) ;;
    esac
    build "registers-$tier" "$cases/registers.ab" "${settings[@]}" ||
        { cat "$output/registers-$tier.trace" >&2; fail "registers.ab under $tier did not build"; }
    [[ $(runs "registers-$tier") == 42 ]] || fail "registers.ab under $tier gave the wrong value"
    ! grep -q '^note\[ct-jit\]: ordinary-global write analysis' "$output/registers-$tier.trace" ||
        { cat "$output/registers-$tier.trace" >&2; fail "registers.ab under $tier: a pass was prepared for abla/json's registrations"; }
done
build bounded-jit "$cases/bounded.ab" ABLA_COMPILE_EVAL=jit ||
    { cat "$output/bounded-jit.trace" >&2; fail "bounded.ab under jit did not build"; }
[[ $(runs bounded-jit) == 42 ]] || fail "bounded.ab under jit gave the wrong values"
[[ $(grep -c '^note\[ct-jit\]: native at' "$output/bounded-jit.trace") == 2 ]] ||
    { cat "$output/bounded-jit.trace" >&2; fail "bounded.ab under jit: not both sites native"; }
# (Without trials: with them, this short recursion finishes in its trial, as in section 4.)
build recursive-auto "$cases/recursive.ab" -u ABLA_COMPILE_EVAL ABLA_COMPILE_EVAL_TRIAL_STEPS=0 ||
    { cat "$output/recursive-auto.trace" >&2; fail "recursive.ab under auto did not build"; }
[[ $(runs recursive-auto) == 42 ]] || fail "recursive.ab under auto gave the wrong value"
grep -q '^note\[ct-jit\]: native at' "$output/recursive-auto.trace" ||
    { cat "$output/recursive-auto.trace" >&2; fail "recursive.ab's site was not native under auto"; }

# 4. Trials (auto): a site that can act on nothing outside the interpreter runs there first, within the pass's
# step budget. trial.ab's short loop finishes, so the pass has no generation; with no budget it is native.
# heavy.ab's trial in section 1 runs out (its loop needs more than the default 1000000 steps) and the site runs
# natively. printing.ab's loop prints, so it gets no trial, and each line is printed once.
build trial-auto "$cases/trial.ab" -u ABLA_COMPILE_EVAL ||
    { cat "$output/trial-auto.trace" >&2; fail "trial.ab under auto did not build"; }
[[ $(runs trial-auto) == 42 ]] || fail "trial.ab under auto gave the wrong value"
! grep -q '^note\[ct-jit\]: \(generation\|native at\)' "$output/trial-auto.trace" ||
    { cat "$output/trial-auto.trace" >&2; fail "trial.ab under auto made a native generation"; }
grep -q '^note\[ct-jit\]: interpreted at [0-9]*: auto: finished in the interpreter in [0-9]* steps' \
    "$output/trial-auto.trace" || { cat "$output/trial-auto.trace" >&2; fail "trial.ab: no finished trial"; }
build trial-none "$cases/trial.ab" -u ABLA_COMPILE_EVAL ABLA_COMPILE_EVAL_TRIAL_STEPS=0 ||
    { cat "$output/trial-none.trace" >&2; fail "trial.ab without trials did not build"; }
grep -q '^note\[ct-jit\]: native at' "$output/trial-none.trace" ||
    { cat "$output/trial-none.trace" >&2; fail "trial.ab without trials was not native"; }
grep -q '^note\[ct-jit\]: trial at .* did not finish after [0-9]* steps' "$output/heavy-unset.trace" ||
    { cat "$output/heavy-unset.trace" >&2; fail "heavy.ab under auto: no trial that ran out"; }
build printing-auto "$cases/printing.ab" -u ABLA_COMPILE_EVAL ||
    { cat "$output/printing-auto.trace" >&2; fail "printing.ab under auto did not build"; }
[[ $(runs printing-auto) == 42 ]] || fail "printing.ab under auto gave the wrong value"
[[ $(grep -c '^compile-eval-tier line' "$output/printing-auto.out") == 3 ]] ||
    { cat "$output/printing-auto.out" "$output/printing-auto.trace" >&2; fail "printing.ab: not three lines once each"; }
! grep -q '^note\[ct-jit\]: trial at' "$output/printing-auto.trace" || fail "printing.ab's site got a trial"
grep -q '^note\[ct-jit\]: native at' "$output/printing-auto.trace" ||
    { cat "$output/printing-auto.trace" >&2; fail "printing.ab's site was not native under auto"; }

echo "compile-eval-tier: ok"
