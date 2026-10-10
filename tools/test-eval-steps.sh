#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/eval-steps"
mkdir -p "$output_directory"
program="$project_root/tests/cases/eval-steps/main.ab"

# The compile-time evaluator counts steps exactly as before: the program takes
# 358, so a limit of 357 stops it at its last step and 358 lets it finish. A
# change to how the evaluator counts (or to how many steps a lookup costs)
# moves this boundary; the 50-million-step limit would move with it.
steps=358
for limit in $((steps - 1)) $steps; do
    set +e
    ABLA_EVAL_STEP_LIMIT=$limit "$compiler" --emit-llvm "$program" \
        >"$output_directory/limit-$limit.out" 2>&1
    status=$?
    set -e
    if [[ $limit -lt $steps ]]; then
        if [[ $status -eq 0 ]] ||
            ! grep -Fq "error[E_EVAL_STEP_LIMIT]: compile-time evaluation ran past $limit steps" \
                "$output_directory/limit-$limit.out"; then
            echo "eval-steps: a limit of $limit did not stop the program" >&2
            sed -n '1,20p' "$output_directory/limit-$limit.out" >&2
            exit 1
        fi
    elif [[ $status -ne 0 ]] || grep -Fq "E_EVAL_STEP_LIMIT" "$output_directory/limit-$limit.out"; then
        echo "eval-steps: a limit of $limit stopped the program" >&2
        grep -m 5 "error" "$output_directory/limit-$limit.out" >&2 || true
        exit 1
    fi
done

"$compiler" build "$program" -o "$output_directory/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
if [[ $status -ne 105 ]]; then
    echo "eval-steps: expected 105, got $status" >&2
    exit 1
fi

echo "eval-steps: the program takes exactly $steps compile-time steps"
