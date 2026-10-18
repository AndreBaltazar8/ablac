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
    run_case "$mode" codec 42
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
# Arrays and objects come back natively; a compiler API call is interpreted, with
# the reason.
native=$(grep -c '^note\[ct-jit\]: native at' "$output_directory/fallback-jit.trace" || true)
[[ $native -eq 3 ]] || { echo "compile-eval-jit: $native native sites in fallback.ab, expected 3" >&2; cat "$output_directory/fallback-jit.trace" >&2; exit 1; }
grep -q 'interpreted at .*: reaches extern:"compiler" fun compilerFindFunction' \
    "$output_directory/fallback-jit.trace"

grep -q 'native at' "$output_directory/codec-jit.trace"
if grep -q 'interpreted at' "$output_directory/codec-jit.trace"; then
    echo "compile-eval-jit: the codec site fell back to the interpreter" >&2
    cat "$output_directory/codec-jit.trace" >&2
    exit 1
fi

# Compile globals: three native sites, then an interpreted one changes the counter, so
# the generation's copy is stale and the last site is interpreted too.
native=$(grep -c '^note\[ct-jit\]: native at' "$output_directory/globals-jit.trace" || true)
[[ $native -eq 3 ]] || { echo "compile-eval-jit: $native native sites in globals.ab, expected 3" >&2; cat "$output_directory/globals-jit.trace" >&2; exit 1; }
grep -q 'interpreted at .*: compile global .*counter changed in an interpreted evaluation' \
    "$output_directory/globals-jit.trace"

# A native compile-time code that stops is a diagnostic; the compiler survives it (an
# error status, not a signal or a panic's 101). Each case: name, mode, environment.
stop_case() { # name mode [VAR=value...]
    local name=$1 mode=$2 status
    shift 2
    set +e
    env "$@" ABLA_COMPILE_EVAL=$mode ABLA_COMPILE_EVAL_TRACE=1 "$compiler" build \
        "$cases/$name.ab" -o "$output_directory/$name-$mode" --no-cache \
        2> "$output_directory/$name-$mode.trace"
    status=$?
    set -e
    if [[ $status -eq 0 || $status -ge 101 ]]; then
        echo "compile-eval-jit: $name.ab under $mode compiled with status $status" >&2
        cat "$output_directory/$name-$mode.trace" >&2
        exit 1
    fi
}

# A runtime panic is the interpreter's error, same code and text, at the site; the
# sites after it are interpreted.
for name in stop stop-divide; do
    stop_case "$name" jit
    stop_case "$name" interp
    jit_error=$(grep -m1 '^error\[' "$output_directory/$name-jit.trace")
    interp_error=$(grep -m1 '^error\[' "$output_directory/$name-interp.trace")
    if [[ $jit_error != "$interp_error" ]]; then
        echo "compile-eval-jit: $name.ab: native \"$jit_error\", interpreter \"$interp_error\"" >&2
        exit 1
    fi
done
grep -q '^error\[E_EVAL_OUT_OF_BOUNDS\]: index 5 out of bounds for array of size 2$' \
    "$output_directory/stop-jit.trace"
grep -q 'interpreted at .*: an earlier compile-time evaluation of this pass stopped' \
    "$output_directory/stop-jit.trace"
grep -q '^error\[E_EVAL_DIVISION_BY_ZERO\]: division by zero$' \
    "$output_directory/stop-divide-jit.trace"

# An endless native evaluation stops at the time limit.
stop_case endless jit ABLA_COMPILE_EVAL_TIME_LIMIT=1
grep -q 'error\[E_CT_TIME_LIMIT\]: compile-time evaluation at .*endless.ab:[0-9]* ran past the time limit (1 s' \
    "$output_directory/endless-jit.trace"

# Recursion past the end of the stack in native code is a diagnostic too.
stop_case deep jit
grep -q 'error\[E_CT_STOPPED\]: compile-time evaluation at .*deep.ab:[0-9]* stopped: a bad memory access' \
    "$output_directory/deep-jit.trace"

echo "compile-eval-jit: native compile-time sites agree with the interpreter"
