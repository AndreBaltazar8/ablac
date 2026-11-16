#!/usr/bin/env bash
# A call's evaluator shares empty scope arrays until its first push (BootstrapEvaluator.ownScopes, src/eval.ab):
# a push that skipped ownScopes would write into the shared arrays, and every later call would see its leaf.
# So the evaluator's five scope arrays are appended to only inside pushProjectionOwner, pushContainerSource and
# pushLoopMapView (the lines marked `scopes-guard`), and the shared empty arrays never. The lowerer (src/ir.ab,
# src/generator_ir.ab) has fields of the same names of its own, which this leaves alone.
#
#   tools/test-eval-scopes-guard.sh
set -euo pipefail

project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
sources=(src/eval.ab src/eval_*.ab src/generator_eval.ab src/ct_*.ab)
fields='projectionOwnerLeaves|projectionOwnerSlots|containerSourceLeaves|containerSourceFlags|loopMapViews'
failed=0
while IFS= read -r line; do
    echo "eval scopes guard: a push that skips ownScopes: $line"
    failed=1
done < <(grep -nE "\.($fields)\.(append|insert|set)\(|\.($fields)\[[^]]*\] *=[^=]" "${sources[@]}" | grep -v '// scopes-guard: the push' || true)
while IFS= read -r line; do
    echo "eval scopes guard: the shared empty scopes are written: $line"
    failed=1
done < <(grep -nE 'BOOTSTRAP_EVAL_NO_SCOPE_(LEAVES|SLOTS)\.(append|insert|set)\(|BOOTSTRAP_EVAL_NO_SCOPE_(LEAVES|SLOTS)\[' "${sources[@]}" || true)
pushes=$(grep -c '// scopes-guard: the push' src/eval.ab || true)
[[ $pushes -eq 5 ]] || { echo "eval scopes guard: expected the 5 marked appends in the push methods, found $pushes"; failed=1; }
(( failed == 0 )) || exit 1
echo "eval scopes guard: the evaluator's scope arrays are pushed only through ownScopes"
