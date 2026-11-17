#!/usr/bin/env bash
# The build cache keys on the compile-time tier (bootstrapCtCacheTier): tiers can disagree, so a build cached under
# one is never reused under another. heavy.ab's site runs natively under jit but stops at a lowered step limit in the
# evaluator: built under jit, then under interp with the same cache, the second build must still fail; built again
# under jit, it hits the cache.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* ]] || compiler=$PWD/$compiler
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source=$project_root/tests/cases/compile-eval-cache-tier/heavy.ab
output=$project_root/build/compile-eval-cache-tier
rm -rf "$output"
mkdir -p "$output"
fail() { echo "compile-eval-cache-tier: $*" >&2; exit 1; }
build() { # tier log
    env ABLA_COMPILE_EVAL="$1" ABLA_COMPILE_EVAL_TRACE=1 ABLA_EVAL_STEP_LIMIT=100000 ABLA_CACHE_DIR="$output/cache" \
        "$compiler" build "$source" -o "$output/program" >"$output/$2" 2>&1
}
build jit jit.log || { cat "$output/jit.log" >&2; fail "heavy.ab did not build under jit"; }
grep -q '^note\[ct-jit\]: native at' "$output/jit.log" || { cat "$output/jit.log" >&2; fail "the site was not native under jit"; }
status=0
"$output/program" || status=$?
[[ $status == 42 ]] || fail "the jit build gave $status"
if build interp interp.log; then
    fail "an interp build reused the jit build's cached object (it must stop at the step limit)"
fi
grep -q 'E_EVAL_STEP_LIMIT' "$output/interp.log" || { cat "$output/interp.log" >&2; fail "interp did not stop at the step limit"; }
build jit jit-again.log || { cat "$output/jit-again.log" >&2; fail "heavy.ab did not build under jit again"; }
! grep -q 'native at' "$output/jit-again.log" || fail "the second jit build did not hit the cache"
echo "compile-eval-cache-tier: a build cached under one tier is not reused under another"
