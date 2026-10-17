#!/usr/bin/env bash
# Integer division, bounds checks, stack overflow and string ordering, at run
# time and under `#`: a zero divisor, an index out of bounds and (at run time) a
# stack overflow panic with their reason (exit 101); the first two are
# positioned errors at compile time; MIN / -1 wraps at every width, also in
# WebAssembly; a constant zero divisor and an ordering of something other than
# numbers and strings are errors.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/runtime-checks"
out="$project_root/build/runtime-checks"
mkdir -p "$out"

fail() { echo "runtime checks: $*" >&2; exit 1; }

# The same text at run time and under `#`, and the expected text.
"$compiler" build "$cases/arithmetic.ab" -o "$out/arithmetic" --no-cache
"$out/arithmetic" > "$out/arithmetic.out"
[[ $(sed -n 1p "$out/arithmetic.out") == "$(sed -n 2p "$out/arithmetic.out")" ]] ||
    fail "division differs under #"
grep -q -- ' -9223372036854775808:0 -9223372036854775808:0 16938 -9223372036854775808 0$' \
    "$out/arithmetic.out" || fail "MIN / -1 does not wrap"

"$compiler" build "$cases/string-order.ab" -o "$out/string-order" --no-cache
"$out/string-order" > "$out/string-order.out"
[[ $(sed -n 1p "$out/string-order.out") == "$(sed -n 2p "$out/string-order.out")" ]] ||
    fail "string order differs under #"
expected_order=' <<= >>= <=>= <<= <<= >>= >>= <<= >>= <<= [][Zebra][apple][apples][fig][pear][été]'
[[ $(sed -n 1p "$out/string-order.out") == "$expected_order" ]] ||
    fail "string order: $(sed -n 1p "$out/string-order.out")"

"$compiler" build "$cases/widths.ab" -o "$out/widths" --no-cache
"$out/widths" > "$out/widths.out"
expected_widths='-128 0 -32768 0 -2147483648 0 6148914691236517205 0 1 35 5 3 2'
printf '%s\n' "$expected_widths" "$expected_widths" | cmp -s - "$out/widths.out" ||
    fail "widths: $(cat "$out/widths.out")"
for which in int rem u8 i32 u64; do
    set +e
    "$out/widths" "$which" > /dev/null 2> "$out/widths-$which.err"
    status=$?
    set -e
    [[ $status -eq 101 ]] || fail "$which / 0 exited $status"
    grep -qx 'panic: division by zero' "$out/widths-$which.err" ||
        fail "$which / 0: $(cat "$out/widths-$which.err")"
done

"$compiler" build "$cases/bounds.ab" -o "$out/bounds" --no-cache
expect_panic() {
    local which=$1 message=$2 status
    set +e
    "$out/bounds" "$which" > /dev/null 2> "$out/bounds-$which.err"
    status=$?
    set -e
    [[ $status -eq 101 ]] || fail "$which exited $status"
    grep -qxF "panic: $message" "$out/bounds-$which.err" ||
        fail "$which: $(cat "$out/bounds-$which.err")"
}
expect_panic array-read "index 5 out of bounds for array of size 3"
expect_panic array-write "index 5 out of bounds for array of size 3"
expect_panic array-negative "index -5 out of bounds for array of size 3"
expect_panic string-array "index 5 out of bounds for array of size 2"
expect_panic string-array-write "index -1 out of bounds for array of size 2"
expect_panic bool-array "index 5 out of bounds for array of size 1"
expect_panic string-index "index 6 out of bounds for string of size 5"
expect_panic slice "slice 3..10 out of bounds for string of size 5"
expect_panic slice-reversed "slice 4..2 out of bounds for string of size 5"
expect_panic truncate "truncate to a negative size (-1)"
expect_panic filled "filledArray with a negative size (-4)"
[[ $("$out/bounds") == ok ]] || fail "bounds without a panic"

# A panic on any thread or coroutine ends the whole process at once, built and
# under `ablac run`.
"$compiler" build "$cases/concurrent.ab" -o "$out/concurrent" --no-cache
for which in main thread task generator thread-panic; do
    message='panic: index 5 out of bounds for array of size 2'
    [[ $which == thread-panic ]] && message='panic: from a thread'
    for mode in built run; do
        set +e
        if [[ $mode == built ]]; then
            "$out/concurrent" "$which" > "$out/concurrent.out" 2> "$out/concurrent.err"
        else
            "$compiler" run "$cases/concurrent.ab" -- "$which" \
                > "$out/concurrent.out" 2> "$out/concurrent.err"
        fi
        status=$?
        set -e
        [[ $status -eq 101 ]] || fail "$which ($mode) exited $status"
        grep -qxF "$message" "$out/concurrent.err" ||
            fail "$which ($mode): $(head -3 "$out/concurrent.err")"
        ! grep -q finished "$out/concurrent.out" || fail "$which ($mode) went on"
    done
done

# A debug build prints the stack after the panic.
"$compiler" build "$cases/bounds.ab" -o "$out/bounds-debug" --no-cache -g
set +e
"$out/bounds-debug" array-read > /dev/null 2> "$out/bounds-debug.err"
status=$?
set -e
[[ $status -eq 101 ]] || fail "debug build exited $status"
grep -qx 'panic: index 5 out of bounds for array of size 3' "$out/bounds-debug.err" ||
    fail "debug build message"
grep -q '^stack ' "$out/bounds-debug.err" || fail "debug build printed no stack"

# A stack overflow panics; another SIGSEGV still ends the process by the signal.
for flags in "" "-g"; do
    "$compiler" build "$cases/stack.ab" -o "$out/stack" --no-cache $flags
    set +e
    "$out/stack" overflow > /dev/null 2> "$out/stack-overflow.err"
    overflow_status=$?
    "$out/stack" segv > /dev/null 2> "$out/stack-segv.err"
    segv_status=$?
    set -e
    [[ $overflow_status -eq 101 ]] || fail "stack overflow$flags exited $overflow_status"
    grep -qx 'panic: stack overflow' "$out/stack-overflow.err" ||
        fail "stack overflow$flags: $(head -3 "$out/stack-overflow.err")"
    [[ $segv_status -eq 139 ]] || fail "SIGSEGV$flags exited $segv_status"
    ! grep -q 'stack overflow' "$out/stack-segv.err" ||
        fail "SIGSEGV$flags taken for a stack overflow"
    [[ $("$out/stack") == "ok 500" ]] || fail "stack$flags without an overflow"
done

# Under `#`: positioned errors with the same text.
set +e
"$compiler" build "$cases/compile-time-panics.ab" -o "$out/compile-time-panics" \
    --no-cache > "$out/compile-time-panics.err" 2>&1
status=$?
set -e
[[ $status -ne 0 ]] || fail "compile-time panics compiled"
for message in \
    'error[E_EVAL_DIVISION_BY_ZERO]: division by zero' \
    'error[E_EVAL_OUT_OF_BOUNDS]: index 5 out of bounds for array of size 3' \
    'error[E_EVAL_OUT_OF_BOUNDS]: index -1 out of bounds for string of size 3' \
    'error[E_EVAL_OUT_OF_BOUNDS]: slice 3..10 out of bounds for string of size 5' \
    'error[E_EVAL_OUT_OF_BOUNDS]: truncate to a negative size (-1)' \
    'error[E_EVAL_OUT_OF_BOUNDS]: index 3 out of bounds for array of size 1' \
    'error[E_EVAL_OUT_OF_BOUNDS]: filledArray with a negative size (-2)'; do
    grep -qF "$message" "$out/compile-time-panics.err" ||
        fail "missing under #: $message"
done
[[ $(grep -c 'E_EVAL_DIVISION_BY_ZERO' "$out/compile-time-panics.err") -eq 2 ]] ||
    fail "expected two divisions by zero under #"

# A constant zero divisor; an order of something that has none.
set +e
"$compiler" build "$cases/invalid-division-zero.ab" -o "$out/invalid" \
    --no-cache > "$out/division-zero.err" 2>&1
division_status=$?
"$compiler" build "$cases/invalid-ordering.ab" -o "$out/invalid" \
    --no-cache > "$out/ordering.err" 2>&1
ordering_status=$?
set -e
[[ $division_status -ne 0 && $ordering_status -ne 0 ]] ||
    fail "invalid programs compiled"
[[ $(grep -c 'division.zero@' "$out/division-zero.err") -eq 5 ]] ||
    fail "division.zero: $(cat "$out/division-zero.err")"
[[ $(grep -c 'comparison.type' "$out/ordering.err") -eq 4 ]] ||
    fail "comparison.type: $(cat "$out/ordering.err")"

# WebAssembly, where the division instructions trap by themselves.
if command -v node > /dev/null; then
    (cd "$project_root" && "$compiler" build "$cases/wasm/build.ab" \
        -o "$out/wasm-driver" --no-cache)
    "$out/wasm-driver"
    node "$cases/wasm/run.mjs" "$out/runtime-checks.wasm"
fi
echo "runtime checks: division, bounds and string order agree at run time and under #"
