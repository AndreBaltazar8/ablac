#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
output_directory=$project_root/build/tests/ownership-shadows-and-globals
cases=$project_root/tests/cases/modules

mkdir -p "$output_directory"
"$compiler" build "$cases/ownership-shadows-and-globals.ab" \
    -o "$output_directory/program" --no-cache --fast
set +e
"$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    printf 'ownership shadows and globals: exited %d, expected 42\n' \
        "$status" >&2
    exit 1
fi

set +e
"$compiler" build "$cases/invalid-receiver-shadowed-late.ab" \
    -o "$output_directory/invalid" --no-cache --fast \
    > "$output_directory/invalid.out" 2>&1
invalid_status=$?
set -e
[[ $invalid_status -ne 0 ]] || exit 1
grep -q 'ownership.mutable-borrow:receiver.Obj.sneaky' \
    "$output_directory/invalid.out"

for invalid in invalid-move-used-after invalid-move-in-loop; do
    set +e
    "$compiler" build "$cases/$invalid.ab" \
        -o "$output_directory/$invalid" --no-cache --fast \
        > "$output_directory/$invalid.out" 2>&1
    move_status=$?
    set -e
    [[ $move_status -ne 0 ]] || exit 1
    grep -q 'ownership\.' "$output_directory/$invalid.out"
done

"$compiler" build "$cases/constructor-stores-parameter.ab" \
    -o "$output_directory/stores-parameter" --no-cache --fast
set +e
"$output_directory/stores-parameter"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1

for invalid in invalid-constructor-stores-var-parameter \
    invalid-constructor-stores-shadowed-parameter; do
    set +e
    "$compiler" build "$cases/$invalid.ab" \
        -o "$output_directory/$invalid" --no-cache --fast \
        > "$output_directory/$invalid.out" 2>&1
    stores_status=$?
    set -e
    [[ $stores_status -ne 0 ]] || exit 1
    grep -q 'ownership.borrow-escape' "$output_directory/$invalid.out"
done

set +e
"$compiler" build "$cases/invalid-borrow-conflict.ab" \
    -o "$output_directory/borrow-conflict" --no-cache --fast \
    > "$output_directory/borrow-conflict.out" 2>&1
conflict_status=$?
set -e
[[ $conflict_status -ne 0 ]] || exit 1
grep -q 'E_BORROW_CONFLICT\]: in `main`, `nums\[0\]` is changed while `first`' \
    "$output_directory/borrow-conflict.out"
grep -q 'in `Box.grow`, `this.items` is changed while `shared`' \
    "$output_directory/borrow-conflict.out"
grep -q '0 semantic, 2 IR, 2 total error' "$output_directory/borrow-conflict.out"

"$compiler" build "$cases/shared-loop-elements.ab" \
    -o "$output_directory/shared-loop" --no-cache --fast
set +e
"$output_directory/shared-loop"
status=$?
set -e
[[ $status -eq 42 ]] || exit 1

for invalid in invalid-shared-loop-append invalid-shared-loop-nested \
    invalid-shared-loop-var-argument; do
    set +e
    "$compiler" build "$cases/$invalid.ab" \
        -o "$output_directory/$invalid" --no-cache --fast \
        > "$output_directory/$invalid.out" 2>&1
    loop_status=$?
    set -e
    [[ $loop_status -ne 0 ]] || exit 1
    grep -q 'ownership\.\(borrow-mutation\|mutable-borrow\)' \
        "$output_directory/$invalid.out"
done

printf '%s\n' 'shadowing locals leave the receiver alone; global-rooted references return; returned objects may store parameters; borrow conflicts are named; shared loop elements stay read-only'
