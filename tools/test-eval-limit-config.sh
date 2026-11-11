#!/usr/bin/env bash
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$project_root/build/eval-limit-config"
mkdir -p "$out"
source="$project_root/tests/cases/eval-steps/raised-limit.ab"
for limit in default 100000000; do
    set +e
    if [[ $limit == default ]]; then
        env -u ABLA_EVAL_STEP_LIMIT ABLA_COMPILE_EVAL=interp "$compiler" --emit-llvm "$source" > "$out/$limit.log" 2>&1
    else
        ABLA_EVAL_STEP_LIMIT=$limit ABLA_COMPILE_EVAL=interp "$compiler" --emit-llvm "$source" > "$out/$limit.log" 2>&1
    fi
    status=$?
    set -e
    if [[ $limit == default ]]; then
        [[ $status -eq 1 ]] && grep -q 'error\[E_EVAL_STEP_LIMIT\].*50000000 steps' "$out/$limit.log" || {
            cat "$out/$limit.log" >&2; exit 1;
        }
        grep -q ABLA_EVAL_STEP_LIMIT "$out/$limit.log"
    elif [[ $status -ne 0 ]]; then
        echo "eval-limit-config: raising the step limit failed" >&2
        cat "$out/$limit.log" >&2
        exit 1
    fi
done
# Invalid and overflowing text keeps the default instead of wrapping or stopping
# a small ordinary evaluation. The exact lower-limit boundary is tested separately.
for limit in '' 0 -1 abc 100x 1000000000000000000 9223372036854775808 0000000000000000001; do
    ABLA_EVAL_STEP_LIMIT=$limit ABLA_COMPILE_EVAL=interp "$compiler" --emit-llvm \
        "$project_root/tests/cases/eval-steps/main.ab" > "$out/invalid.log" 2>&1
done
echo 'eval-limit-config: default 50M stops; explicit 100M finishes; invalid settings keep default'
