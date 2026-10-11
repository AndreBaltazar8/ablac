#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/borrow-lifetimes"
source_file="$project_root/tests/cases/modules/borrow-lifetimes.ab"
mkdir -p "$output_directory"

"$compiler" --emit-llvm "$source_file" > "$output_directory/program.ll"
opt --threads=1 -passes=verify -disable-output "$output_directory/program.ll"

"$compiler" build "$source_file" -o "$output_directory/program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
native_status=$?
set -e
if [[ $native_status -ne 42 ]]; then
    echo "borrow lifetimes: LLVM expected 42, got $native_status" >&2
    exit 1
fi

fixtures=(
    invalid-borrow-active-move
    invalid-borrow-conditional-move
    invalid-borrow-chain-active-move
    invalid-borrow-active-assignment
    invalid-borrow-active-mutable-call
    invalid-borrow-active-mutating-receiver
    invalid-borrow-temporary-source
    invalid-borrow-mutable-local
    invalid-borrow-capture
    invalid-borrow-conditional-source
    invalid-borrow-when-source
    invalid-borrow-return-source
    invalid-borrow-return-active-move
    invalid-borrow-return-call-overlap
    invalid-borrow-return-source-mode
    invalid-borrow-return-source-name
    invalid-borrow-return-indirect
    invalid-borrow-return-indirect-global
    invalid-borrow-return-indirect-index
    invalid-borrow-return-indirect-mode
    invalid-borrow-return-source-default
    invalid-staged-runtime-borrow-active-move
    invalid-staged-method-borrow-active-move
    invalid-staged-borrow-return-active-move
    invalid-staged-indirect-borrow-return-active-move
    invalid-borrow-mutating-receiver-later-extension
    invalid-compile-borrow-active-move
)
diagnostics=(
    'error[E_BORROW_CONFLICT]: in `main`, `owner` is changed while `view`'
    'error[E_BORROW_CONFLICT]: in `inspect`, `owner` is changed while `view`'
    'error[E_BORROW_CONFLICT]: in `main`, `owner` is changed while `tickets`'
    'error[E_BORROW_CONFLICT]: in `main`, `owner` is changed while `view`'
    'error[E_BORROW_CONFLICT]: in `main`, `holder.handle` is changed while `view`'
    'error[E_BORROW_CONFLICT]: in `main`, `holder.handle` is changed while `view`'
    'ownership.borrow-source:view'
    'ownership.borrow-mutable-local:view'
    'ownership.borrow-capture:view'
    'ownership.borrow-source:view'
    'ownership.borrow-source:view'
    'ownership.borrow-return-source:function.wrongOwner:left'
    'error[E_BORROW_CONFLICT]: in `main`, `owner` is changed while `borrowed`'
    'ownership.borrow-own-alias:function.observeAndConsume'
    'ownership.borrow-return-source-mode:consumedView:owner'
    'ownership.borrow-return-source-name:invalidSourceName:missing'
    'error[E_BORROW_CONFLICT]: in `main`, `owner` is changed while `borrowed`'
    'error[E_BORROW_CONFLICT]: in `main`, `owner` is changed while `borrowed`'
    'ownership.borrow-return-indirect-source:callback'
    'ownership.borrow-return-indirect-mode:callback'
    'ownership.borrow-return-source-default:defaultedView:owner'
    'error[E_BORROW_CONFLICT]: in `invalidRuntimeBorrowLifetime`, `owner` is changed while `view`'
    'error[E_BORROW_CONFLICT]: in `Inspector_invalidBorrowLifetime`, `owner` is changed while `view`'
    'error[E_BORROW_CONFLICT]: in `invalidReturnedBorrowLifetime`, `owner` is changed while `borrowed`'
    'error[E_BORROW_CONFLICT]: in `invalidIndirectBorrowLifetime`, `owner` is changed while `borrowed`'
    'error[E_BORROW_CONFLICT]: in `main`, `holder.handle` is changed while `view`'
    'error[E_BORROW_CONFLICT]: in `invalidBorrowLifetime`, `owner` is changed while `view`'
)

index=0
while [[ $index -lt ${#fixtures[@]} ]]; do
    fixture=${fixtures[$index]}
    expected=${diagnostics[$index]}
    output="$output_directory/$fixture"
    rm -f "$output"
    set +e
    "$compiler" build \
        "$project_root/tests/cases/bootstrap/$fixture.ab" \
        -o "$output" >"$output.out" 2>"$output.err"
    status=$?
    set -e
    if [[ $status -ne 1 ]] || ! grep -Fq "$expected" "$output.err"; then
        echo "borrow lifetimes: $fixture was not rejected with $expected" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]] || exit 1
    index=$((index + 1))
done

# A compile fun nothing calls: `build` prunes it, but --emit-llvm checks every
# body, and its conflict is named like a called one's.
uncalled="$output_directory/invalid-compile-borrow-active-move-uncalled"
set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/bootstrap/invalid-compile-borrow-active-move-uncalled.ab" \
    >"$uncalled.out" 2>"$uncalled.err"
status=$?
set -e
if [[ $status -ne 1 ]] ||
    ! grep -Fq 'error[E_BORROW_CONFLICT]: in `invalidBorrowLifetime`, `owner` is changed while `view`' "$uncalled.err"; then
    echo "borrow lifetimes: the uncalled compile fun's conflict was not named (exit $status)" >&2
    sed -n '1,20p' "$uncalled.err" >&2
    exit 1
fi

echo 'borrow lifetimes: direct/indirect/global/returned callable contracts + stored/chained views + CFG/staged verification + LLVM passed'
