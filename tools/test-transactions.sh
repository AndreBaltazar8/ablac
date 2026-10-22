#!/usr/bin/env bash
# Transactions in the language (`TVar`, `atomic`, `retry`, `orElse`): their
# semantics on one thread under both compile-time evaluators, the bank and
# channel programs under real contention over many runs, and each check's
# diagnostic.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/transactions"
mkdir -p "$output_directory"
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}
export ABLA_MAX_SECONDS=${ABLA_MAX_SECONDS:-300}
export ABLA_MAX_CPU_SECONDS=${ABLA_MAX_CPU_SECONDS:-$ABLA_MAX_SECONDS}
runs=${TRANSACTION_RUNS:-20}

expect_42() {
    set +e
    "$project_root/tools/run-limited.sh" "$@" >"$output_directory/last.out" 2>&1
    local status=$?
    set -e
    if [[ $status -ne 42 ]]; then
        printf 'transactions: %s expected 42, got %s\n' "$1" "$status" >&2
        cat "$output_directory/last.out" >&2
        exit 1
    fi
}

for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build \
        "$project_root/tests/cases/modules/transactions.ab" \
        -o "$output_directory/single-$mode" --no-cache
    expect_42 "$output_directory/single-$mode"
done

for program in surface-bank surface-channel; do
    "$compiler" build "$project_root/tests/cases/stm/$program.ab" \
        -o "$output_directory/$program" --no-cache
    run=0
    while [[ $run -lt $runs ]]; do
        ABLA_MAX_SECONDS=60 expect_42 "$output_directory/$program"
        run=$((run + 1))
    done
done

fixtures=(
    outside-direct outside-helper outside-lambda outside-retry
    effect-io effect-fs effect-thread effect-delegate effect-native
    resource-tvar resource-local
    mutation-local mutation-object mutation-global
    control-return orelse-type
)
diagnostics=(
    'stm.outside-atomic:getValue()' 'stm.outside-atomic:withdraw'
    'stm.outside-atomic:balance' 'stm.outside-atomic:retry'
    'stm.effect:io:println' 'stm.effect:filesystem' 'stm.effect:thread:spawn'
    'stm.effect:io:Loud.getValue' 'stm.effect:native'
    'stm.resource:TVar<Ticket>' 'stm.resource:ticket'
    'stm.outside-mutation:seen' 'stm.outside-mutation:log.append()'
    'stm.outside-mutation:count:calls'
    'stm.control:return' 'stm.orElse-type:i64:string'
)
index=0
while [[ $index -lt ${#fixtures[@]} ]]; do
    fixture=invalid-stm-${fixtures[$index]}
    expected=${diagnostics[$index]}
    output="$output_directory/$fixture"
    rm -f -- "$output"
    set +e
    "$compiler" build "$project_root/tests/cases/modules/$fixture.ab" \
        -o "$output" --no-cache >"$output.out" 2>"$output.err"
    result=$?
    set -e
    errors=$(grep -c '^error\[' "$output.err" || true)
    if [[ $result -ne 1 ]] || ! grep -Fq "$expected" "$output.err" || [[ $errors -ne 1 ]]; then
        printf 'transactions: %s did not report %s alone\n' "$fixture" "$expected" >&2
        sed -n '1,40p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]] || exit 1
    index=$((index + 1))
done

printf 'transactions: semantics (both evaluators), bank and channel under contention (%s runs each), and every check passed\n' "$runs"
