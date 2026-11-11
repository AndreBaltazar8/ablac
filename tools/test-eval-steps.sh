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

# Past the limit the evaluator evaluates nothing more: a loop the limit cuts
# short is not followed by code that would fault on what it left behind
# (stopped.ab), and a value it never finished still lowers (partial.ab).
for case in stopped partial; do
    source="$project_root/tests/cases/eval-steps/$case.ab"
    set +e
    ABLA_EVAL_STEP_LIMIT=100 "$compiler" --emit-llvm "$source" \
        >"$output_directory/$case.out" 2>&1
    status=$?
    set -e
    if [[ $status -ne 1 ]] ||
        ! grep -Fq "error[E_EVAL_STEP_LIMIT]: compile-time evaluation ran past 100 steps" \
            "$output_directory/$case.out"; then
        echo "eval-steps: $case.ab stopped at the limit exited $status without reporting it" >&2
        sed -n '1,20p' "$output_directory/$case.out" >&2
        exit 1
    fi
    "$compiler" build "$source" -o "$output_directory/$case" --no-cache
    set +e
    "$project_root/tools/run-limited.sh" "$output_directory/$case"
    status=$?
    set -e
    if [[ $status -ne 42 ]]; then
        echo "eval-steps: $case.ab without the limit: expected 42, got $status" >&2
        exit 1
    fi
done

# The same missing element without any limit: a compile-time index out of
# range is reported, not a backend fault.
element="$project_root/tests/cases/eval-steps/element.ab"
set +e
"$compiler" --emit-llvm "$element" >"$output_directory/element.out" 2>&1
status=$?
set -e
if [[ $status -ne 1 ]] ||
    ! grep -Fq "error[E_EVAL_OUT_OF_BOUNDS]: index 3 out of bounds for array of size 0" \
        "$output_directory/element.out"; then
    echo "eval-steps: element.ab exited $status without reporting the failed index" >&2
    sed -n '1,20p' "$output_directory/element.out" >&2
    exit 1
fi

# A stopped evaluation is control flow, not an integer zero or a partially
# initialized value. Exercise both operands and bounds, and stop at several
# points within spin's arithmetic so no caller consumes the abandoned value.
expressions=(
    '42 / spin()' '42 % spin()' '[7][spin() - 2]' 'consume(spin())'
    'if (spin() < 3) 42 else 1' '1 << spin()' '"abc".slice(spin() - 2, 2).size'
    '"abc".slice(0, spin()).size' 'filledArray(spin(), 7).size'
    'when (spin()) { 2 -> 42; else -> 1 }' '"x".repeat(spin()).size'
)
case_number=0
for expression in "${expressions[@]}"; do
    source="$output_directory/operand-$case_number.ab"
    : > "$source"
    if [[ $expression == *repeat* ]]; then echo 'import "abla/text"' >> "$source"; fi
    sed "s@#(spin())@#($expression)@" "$project_root/tests/cases/eval-steps/operand-stop.ab" >> "$source"
    for limit in 20 21 22 23 24 25 26 27 28 29; do
        set +e
        ABLA_COMPILE_EVAL=interp ABLA_EVAL_STEP_LIMIT=$limit "$compiler" --emit-llvm "$source" \
            > "$output_directory/operand-$case_number-$limit.out" 2>&1
        status=$?
        set -e
        log="$output_directory/operand-$case_number-$limit.out"
        if [[ $status -ne 1 || $(grep -c '^error\[' "$log") -ne 1 ]] ||
            ! grep -Fq 'error[E_EVAL_STEP_LIMIT]' "$log" ||
            ! grep -Fq 'ABLA_COMPILE_EVAL=jit' "$log"; then
            echo "eval-steps: $expression at $limit steps did not give exactly one step-limit error" >&2
            cat "$log" >&2
            exit 1
        fi
    done
    # The same expression without the cut-off is valid.
    ABLA_COMPILE_EVAL=interp "$compiler" --emit-llvm "$source" > "$output_directory/operand-$case_number-ok.ll"
    case_number=$((case_number + 1))
done

# Genuine faults remain diagnostics, including a different # site in the
# same source as one stopped at its step limit.
source="$output_directory/real-zero.ab"
sed 's@#(spin())@#(consume(0))@' "$project_root/tests/cases/eval-steps/operand-stop.ab" > "$source"
set +e
ABLA_COMPILE_EVAL=interp "$compiler" --emit-llvm "$source" > "$output_directory/real-zero.out" 2>&1
status=$?
set -e
[[ $status -eq 1 ]] && grep -Fq 'error[E_EVAL_DIVISION_BY_ZERO]' "$output_directory/real-zero.out" || {
    echo "eval-steps: genuine division by zero was lost" >&2
    cat "$output_directory/real-zero.out" >&2
    exit 1
}

echo 'val stopped = #spin()' >> "$source"
set +e
ABLA_COMPILE_EVAL=interp ABLA_EVAL_STEP_LIMIT=100 "$compiler" --emit-llvm "$source" > "$output_directory/independent.out" 2>&1
status=$?
set -e
if [[ $status -ne 1 || $(grep -c '^error\[' "$output_directory/independent.out") -ne 2 ]] ||
    ! grep -Fq 'error[E_EVAL_STEP_LIMIT]' "$output_directory/independent.out" ||
    ! grep -Fq 'error[E_EVAL_DIVISION_BY_ZERO]' "$output_directory/independent.out"; then
    echo "eval-steps: a stopped site hid or multiplied an independent error" >&2
    cat "$output_directory/independent.out" >&2
    exit 1
fi

# A subparser must not consume the default cursor handle or report its own
# failure after an argument stopped. Its abandoned syntax remains diagnosed once.
for name in main message; do
    set +e
    ABLA_COMPILE_EVAL=interp ABLA_EVAL_STEP_LIMIT=100 "$compiler" --emit-llvm \
        "$project_root/tests/cases/eval-steps/parser-stop/$name.ab" > "$output_directory/parser-$name.out" 2>&1
    status=$?
    set -e
    if [[ $status -ne 1 || $(grep -c '^error\[' "$output_directory/parser-$name.out") -ne 1 ]] ||
        ! grep -Fq 'error[E_EVAL_STEP_LIMIT]' "$output_directory/parser-$name.out"; then
        echo "eval-steps: parser $name consumed a stopped argument" >&2
        cat "$output_directory/parser-$name.out" >&2
        exit 1
    fi
done

echo "eval-steps: the program takes exactly $steps compile-time steps; the limit stops evaluation"
