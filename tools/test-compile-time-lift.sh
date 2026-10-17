#!/usr/bin/env bash
# Compile-time results of every liftable type become equal program values
# (closures included); the others fail with a diagnostic naming the type.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/compile-time-lift"
output_directory="$project_root/build/compile-time-lift"
mkdir -p "$output_directory"

# Lifted directly, then through the codec the compile-time JIT hands its
# results over in (encoded, decoded, encoded again: the same bytes).
for check in 0 1; do
    for name in closures values; do
        ABLA_LIFT_CODEC_CHECK=$check "$compiler" build "$cases/$name.ab" \
            -o "$output_directory/$name" --no-cache
        set +e
        "$output_directory/$name"
        status=$?
        set -e
        if [[ $status -ne 42 ]]; then
            expect_failure invalid-resource \
    'resource class `Handle` (in Holder.handle) cannot become a program value'
echo "compile-time lift: $name (codec check $check) exited $status" >&2
            exit 1
        fi
    done
done

expect_failure() { # <case> <text the diagnostics must contain>
    set +e
    "$compiler" build "$cases/$1.ab" -o "$output_directory/$1" --no-cache \
        > "$output_directory/$1.out" 2>&1
    local status=$?
    set -e
    if [[ $status -eq 0 ]] || ! grep -qF -- "$2" "$output_directory/$1.out"; then
        expect_failure invalid-resource \
    'resource class `Handle` (in Holder.handle) cannot become a program value'
echo "compile-time lift: $1 did not report: $2" >&2
        cat "$output_directory/$1.out" >&2
        exit 1
    fi
    if grep -q 'E_LLVM\|E_IR_' "$output_directory/$1.out"; then
        expect_failure invalid-resource \
    'resource class `Handle` (in Holder.handle) cannot become a program value'
echo "compile-time lift: $1 reported an IR/LLVM error" >&2
        cat "$output_directory/$1.out" >&2
        exit 1
    fi
}
expect_failure invalid-generator \
    '`Generator<int>` cannot become a program value: a generator is a suspended computation'
expect_failure invalid-resource \
    'resource class `Handle` (in Holder.handle) cannot become a program value'
echo "compile-time lift: closures and data values round-trip"
