#!/usr/bin/env bash
# Compile-time sites run as native code under ABLA_COMPILE_EVAL=jit and give the
# interpreter's results; a site the native tier cannot take yet is interpreted.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/compile-eval-jit"
output_directory="$project_root/build/compile-eval-jit"
mkdir -p "$output_directory"

run_case() { # mode name expected-status
    local mode=$1 name=$2 expected=$3
    ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build \
        "$cases/$name.ab" -o "$output_directory/$name-$mode" --no-cache \
        2> "$output_directory/$name-$mode.trace"
    set +e
    "$output_directory/$name-$mode"
    local status=$?
    set -e
    if [[ $status -ne $expected ]]; then
        echo "compile-eval-jit: $name under $mode exited $status, expected $expected" >&2
        cat "$output_directory/$name-$mode.trace" >&2
        exit 1
    fi
}

for mode in interp jit; do
    run_case "$mode" scalars 42
    run_case "$mode" fallback 33
    run_case "$mode" globals 42
done

# Every scalar site (six expressions and one action) ran natively.
native=$(grep -c '^note\[ct-jit\]: native at' "$output_directory/scalars-jit.trace" || true)
if [[ $native -ne 7 ]]; then
    echo "compile-eval-jit: $native native sites in scalars.ab, expected 7" >&2
    cat "$output_directory/scalars-jit.trace" >&2
    exit 1
fi
if grep -q 'interpreted at' "$output_directory/scalars-jit.trace"; then
    echo "compile-eval-jit: a scalar site fell back to the interpreter" >&2
    cat "$output_directory/scalars-jit.trace" >&2
    exit 1
fi
# The interpreter tier never prepares a slice.
if grep -q 'ct-jit' "$output_directory/scalars-interp.trace"; then
    echo "compile-eval-jit: the interpreter tier used the native tier" >&2
    exit 1
fi
# Results without an encoder are interpreted, with the reason.
grep -q 'interpreted at .*: result type array:i64 has no encoder yet' \
    "$output_directory/fallback-jit.trace"
grep -q 'interpreted at .*: result type Pair has no encoder yet' \
    "$output_directory/fallback-jit.trace"
grep -q 'native at' "$output_directory/fallback-jit.trace"

# Compile globals: three native sites, then an interpreted one changes the counter, so
# the generation's copy is stale and the last site is interpreted too.
native=$(grep -c '^note\[ct-jit\]: native at' "$output_directory/globals-jit.trace" || true)
[[ $native -eq 3 ]] || { echo "compile-eval-jit: $native native sites in globals.ab, expected 3" >&2; cat "$output_directory/globals-jit.trace" >&2; exit 1; }
grep -q 'interpreted at .*: compile global .*counter changed in an interpreted evaluation' \
    "$output_directory/globals-jit.trace"

# A runtime stop in native compile-time code is a diagnostic; the compiler survives
# it (an error status, not a signal) and interprets the sites after it.
set +e
ABLA_COMPILE_EVAL=jit ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build "$cases/stop.ab" \
    -o "$output_directory/stop-jit" --no-cache 2> "$output_directory/stop-jit.trace"
status=$?
set -e
if [[ $status -eq 0 || $status -ge 101 ]]; then
    echo "compile-eval-jit: stop.ab compiled with status $status" >&2
    cat "$output_directory/stop-jit.trace" >&2
    exit 1
fi
grep -q 'error\[E_CT_STOPPED\]: compile-time evaluation at .*stop.ab:[0-9]* stopped: panic: index 5 out of bounds for array of size 2' \
    "$output_directory/stop-jit.trace"
grep -q 'interpreted at .*: an earlier compile-time evaluation of this pass stopped' \
    "$output_directory/stop-jit.trace"

# A division by zero is a runtime panic: it stops the same way, with its message.
set +e
ABLA_COMPILE_EVAL=jit ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build "$cases/stop-divide.ab" \
    -o "$output_directory/stop-divide-jit" --no-cache 2> "$output_directory/stop-divide-jit.trace"
status=$?
set -e
if [[ $status -eq 0 || $status -ge 101 ]]; then
    echo "compile-eval-jit: stop-divide.ab compiled with status $status" >&2
    cat "$output_directory/stop-divide-jit.trace" >&2
    exit 1
fi
grep -q 'error\[E_CT_STOPPED\]: compile-time evaluation at .*stop-divide.ab:[0-9]* stopped: panic: division by zero' \
    "$output_directory/stop-divide-jit.trace"

echo "compile-eval-jit: native compile-time sites agree with the interpreter"
