#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/affine-move"
mkdir -p "$output_directory"

"$compiler" build "$project_root/tests/cases/modules/affine-move.ab" \
    -o "$output_directory/program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/program"
status=$?
set -e
if [[ $status -ne 42 ]]; then
    echo "affine move: expected 42, got $status" >&2
    exit 1
fi

"$compiler" build "$project_root/tests/cases/modules/owned-parameters.ab" \
    -o "$output_directory/owned-parameters"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/owned-parameters"
owned_status=$?
set -e
if [[ $owned_status -ne 42 ]]; then
    echo "affine move: owned parameters expected 42, got $owned_status" >&2
    exit 1
fi

"$compiler" build "$project_root/tests/cases/modules/mutable-borrows.ab" \
    -o "$output_directory/mutable-borrows"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/mutable-borrows"
mutable_status=$?
set -e
if [[ $mutable_status -ne 42 ]]; then
    echo "affine move: mutable borrows expected 42, got $mutable_status" >&2
    exit 1
fi

"$compiler" build \
    "$project_root/tests/cases/modules/managed-mutable-views.ab" \
    -o "$output_directory/managed-mutable-views"
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/managed-mutable-views"
managed_mutable_status=$?
set -e
if [[ $managed_mutable_status -ne 42 ]]; then
    echo "ownership: managed mutable views expected 42, got $managed_mutable_status" >&2
    exit 1
fi

"$compiler" build \
    "$project_root/tests/cases/modules/managed-alias-lifetimes.ab" \
    -o "$output_directory/managed-alias-lifetimes"
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/managed-alias-lifetimes"
managed_alias_status=$?
set -e
if [[ $managed_alias_status -ne 42 ]]; then
    echo "ownership: managed aliases expected 42, got $managed_alias_status" >&2
    exit 1
fi

"$compiler" build \
    "$project_root/tests/cases/modules/resource-lambda-capture.ab" \
    -o "$output_directory/resource-lambda-capture"
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/resource-lambda-capture"
capture_status=$?
set -e
if [[ $capture_status -ne 42 ]]; then
    echo "affine move: owning lambda expected 42, got $capture_status" >&2
    exit 1
fi

"$compiler" build \
    "$project_root/tests/cases/modules/resource-lambda-drop.ab" \
    -o "$output_directory/resource-lambda-drop"
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/resource-lambda-drop"
lambda_drop_status=$?
set -e
if [[ $lambda_drop_status -ne 42 ]]; then
    echo "affine move: FnOnce environment drops expected 42, got $lambda_drop_status" >&2
    exit 1
fi

"$compiler" build "$project_root/tests/cases/modules/place-move.ab" \
    -o "$output_directory/place-move"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/place-move"
place_status=$?
set -e
if [[ $place_status -ne 42 ]]; then
    echo "affine move: field/index moves expected 42, got $place_status" >&2
    exit 1
fi

"$compiler" build "$project_root/tests/cases/modules/resource-drop.ab" \
    -o "$output_directory/resource-drop"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/resource-drop"
drop_status=$?
set -e
if [[ $drop_status -ne 42 ]]; then
    echo "affine move: deterministic drops expected 42, got $drop_status" >&2
    exit 1
fi

"$compiler" build \
    "$project_root/tests/cases/modules/resource-structural-drop.ab" \
    -o "$output_directory/resource-structural-drop"
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/resource-structural-drop"
structural_drop_status=$?
set -e
if [[ $structural_drop_status -ne 42 ]]; then
    echo "affine move: structural drops expected 42, got $structural_drop_status" >&2
    exit 1
fi

for program in \
    managed-return-global \
    managed-return-stored-global \
    managed-return-parameter \
    managed-return-this; do
    "$compiler" build "$project_root/tests/cases/bootstrap/$program.ab" \
        -o "$output_directory/$program"
    set +e
    "$project_root/tools/run-limited.sh" "$output_directory/$program"
    program_status=$?
    set -e
    if [[ $program_status -ne 42 ]]; then
        echo "ownership: $program expected 42, got $program_status" >&2
        exit 1
    fi
done

for program in managed-borrow-results inferred-borrow-results; do
    "$compiler" build "$project_root/tests/cases/modules/$program.ab" \
        -o "$output_directory/$program"
    set +e
    "$project_root/tools/run-limited.sh" "$output_directory/$program"
    program_status=$?
    set -e
    if [[ $program_status -ne 42 ]]; then
        echo "ownership: $program expected 42, got $program_status" >&2
        exit 1
    fi
done

# Rejected by the typed-CFG checks after lowering: each failure names the
# mistake, the place and (through source records) where it happens.
check_rejected() {
    local fixture=$1
    local expected=$2
    local output="$output_directory/$fixture"
    rm -f "$output"
    set +e
    "$compiler" build "$project_root/tests/cases/bootstrap/$fixture.ab" \
        -o "$output" >"$output.out" 2>"$output.err"
    local result=$?
    set -e
    if [[ $result -ne 1 ]] || ! grep -Fq -- "$expected" "$output.err"; then
        echo "affine move: $fixture was not rejected with $expected" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    if grep -Fq 'violated a typed IR invariant' "$output.err"; then
        echo "affine move: $fixture has an unnamed verifier failure" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]] || exit 1
}

check_rejected invalid-use-after-move 'ownership.use-after-move:source:'
check_rejected invalid-conditional-move \
    'ownership.use-after-conditional-move:source:'
check_rejected invalid-double-move 'ownership.use-after-move:source:'
for fixture in \
    invalid-managed-alias-active-mutation \
    invalid-stored-reference-active-mutation \
    invalid-compile-stored-reference-active-mutation \
    invalid-transitive-managed-alias-active-mutation \
    invalid-compile-transitive-managed-alias-active-mutation \
    invalid-compile-managed-alias-active-mutation \
    invalid-managed-borrow-result-conflict \
    invalid-managed-borrow-method-conflict \
    invalid-inferred-borrow-wrap \
    invalid-inferred-borrow-parameter \
    invalid-inferred-borrow-receiver; do
    check_rejected "$fixture" 'error[E_BORROW_CONFLICT]:'
done

for fixture in \
    invalid-resource-copy \
    invalid-resource-assignment \
    invalid-resource-branch-copy \
    invalid-borrow-escape \
    invalid-owned-argument \
    invalid-borrow-to-owned \
    invalid-borrow-own-call-alias \
    invalid-borrow-own-method-alias \
    invalid-indirect-owned-argument \
    invalid-indirect-borrow-own-alias \
    invalid-explicit-owned-callable-argument \
    invalid-shared-parameter-mutation \
    invalid-shared-array-mutation \
    invalid-managed-readonly-class-mutation \
    invalid-managed-readonly-array-mutation \
    invalid-managed-readonly-array-append \
    invalid-cell-managed-payload \
    invalid-managed-alias-mutable-local \
    invalid-managed-alias-mutation \
    invalid-managed-alias-escape \
    invalid-stored-reference-multiple \
    invalid-managed-borrow-result-source \
    invalid-managed-mutable-call-alias \
    invalid-managed-mutable-method-alias \
    invalid-managed-overload-freshness \
    invalid-mutable-borrow-type \
    invalid-mutable-borrow-default \
    invalid-mutable-reborrow \
    invalid-mutable-borrow-alias \
    invalid-mutable-method-alias \
    invalid-mutable-extern \
    invalid-owned-method-argument \
    invalid-owned-constructor-argument \
    invalid-resource-lambda-capture \
    invalid-borrowed-move-capture \
    invalid-once-closure-copy \
    invalid-field-extraction \
    invalid-index-extraction \
    invalid-affine-wrapper-copy \
    invalid-borrowed-field-move \
    invalid-global-resource-move \
    invalid-global-resource-return \
    invalid-drop-field-projection; do
    output="$output_directory/$fixture"
    rm -f "$output"
    set +e
    "$compiler" build "$project_root/tests/cases/bootstrap/$fixture.ab" \
        -o "$output" >"$output.out" 2>"$output.err"
    result=$?
    set -e
    expected_diagnostic='ownership.'
    if [[ $fixture == invalid-cell-managed-payload ]]; then
        expected_diagnostic='cell.element-copy:array:i64'
    fi
    if [[ $result -ne 1 ]] ||
        ! grep -Fq "$expected_diagnostic" "$output.err"; then
        echo "affine move: $fixture bypassed resource ownership" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]] || exit 1
done

owned_contract_fixtures=(
    invalid-owned-parameter-type
    invalid-owned-method-parameter-type
    invalid-owned-constructor-parameter
)
owned_contract_diagnostics=(
    'ownership.owned-parameter-type:consume'
    'ownership.owned-parameter-type:Consumer.consume'
    'ownership.owned-constructor-parameter:Sink'
)

owned_contract=0
while [[ $owned_contract -lt ${#owned_contract_fixtures[@]} ]]; do
    fixture=${owned_contract_fixtures[$owned_contract]}
    expected=${owned_contract_diagnostics[$owned_contract]}
    output="$output_directory/$fixture"
    rm -f "$output"
    set +e
    "$compiler" build "$project_root/tests/cases/bootstrap/$fixture.ab" \
        -o "$output" >"$output.out" 2>"$output.err"
    result=$?
    set -e
    if [[ $result -ne 1 ]] || ! grep -Fq "$expected" "$output.err"; then
        echo "affine move: $fixture was not rejected with $expected" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]] || exit 1
    owned_contract=$((owned_contract + 1))
done

output="$output_directory/invalid-owned-callable-mode-mismatch"
rm -f "$output"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-owned-callable-mode-mismatch.ab" \
    -o "$output" >"$output.out" 2>"$output.err"
result=$?
set -e
if [[ $result -ne 1 ]] || ! grep -Fq 'function.argument:' "$output.err"; then
    echo "affine move: callable ownership mode mismatch was accepted" >&2
    sed -n '1,80p' "$output.err" >&2
    exit 1
fi
[[ ! -e $output ]] || exit 1

output="$output_directory/invalid-mutable-callable-mode-mismatch"
rm -f "$output"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-mutable-callable-mode-mismatch.ab" \
    -o "$output" >"$output.out" 2>"$output.err"
result=$?
set -e
if [[ $result -ne 1 ]] || ! grep -Fq 'function.argument:' "$output.err"; then
    echo "affine move: callable mutable mode mismatch was accepted" >&2
    sed -n '1,80p' "$output.err" >&2
    exit 1
fi
[[ ! -e $output ]] || exit 1

for fixture in \
    invalid-resource-drop-signature \
    invalid-resource-drop-duplicate; do
    output="$output_directory/$fixture"
    rm -f "$output"
    set +e
    "$compiler" build "$project_root/tests/cases/bootstrap/$fixture.ab" \
        -o "$output" >"$output.out" 2>"$output.err"
    result=$?
    set -e
    if [[ $result -ne 1 ]] || ! grep -Fq 'resource.drop-' "$output.err"; then
        echo "affine move: $fixture bypassed destructor validation" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]] || exit 1
done


# In a module whose source an import alias rewrites, the records name the
# file's own offsets: 284 is `source[0]`, 250 the `move(source)`.
alias_fixture="$project_root/tests/cases/modules/invalid-move-after-alias.ab"
set +e
"$compiler" build "$alias_fixture" -o "$output_directory/alias-move" \
    >"$output_directory/alias-move.out" 2>"$output_directory/alias-move.err"
set -e
if ! grep -Fq "source[ownership]:$alias_fixture:284:285" \
        "$output_directory/alias-move.err" ||
    ! grep -Fq "source[ownership]:$alias_fixture:250:251" \
        "$output_directory/alias-move.err"; then
    echo "affine move: positions in an aliased module are not the file's" >&2
    sed -n '1,40p' "$output_directory/alias-move.err" >&2
    exit 1
fi

check_rejected invalid-owned-use-after-move 'ownership.use-after-move:ticket:'
check_rejected invalid-capture-use-after-move 'ownership.use-after-move:ticket:'
check_rejected invalid-once-closure-second-call \
    'ownership.once-called-again:callback:'
check_rejected invalid-field-owner-after-move \
    'ownership.use-after-move:box.ticket.value:'
check_rejected invalid-index-owner-after-move \
    'ownership.use-after-move:tickets[0].value:'
check_rejected invalid-partial-owner-use 'ownership.partial-move:box:'
check_rejected invalid-partial-reinitialize-branch 'ownership.partial-move:box:'
check_rejected invalid-dynamic-place-reinitialize 'ownership.partial-move:shelf:'

output="$output_directory/invalid-move-expression"
rm -f "$output"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-move-expression.ab" \
    -o "$output" >"$output.out" 2>"$output.err"
result=$?
set -e
if [[ $result -ne 1 ]] || ! grep -Fq 'move.local' "$output.err"; then
    echo "affine move: non-local move was accepted" >&2
    exit 1
fi
[[ ! -e $output ]] || exit 1

# An assignment's value is what the place now owns: using it (a result, an
# `if` branch whose value is kept) would drop it twice, so it is rejected; a
# statement assignment, a void function ending in one and a non-affine
# assignment's value are fine, and each resource drops once, at run time and
# under `#`.
assignments=$project_root/tests/cases/assignment-value
"$compiler" build "$assignments/assignments.ab" -o "$output_directory/assignments" \
    --no-cache > "$output_directory/assignments.build" 2>&1
set +e
"$output_directory/assignments" > "$output_directory/assignments.out"
status=$?
set -e
if [[ $status -ne 10 || $(cat "$output_directory/assignments.out") != $'drop 4\ndrop 1\ndrop 2\ndrop 3\n10 10' ]]; then
    echo "affine move: assignments dropped wrongly ($status):" >&2
    cat "$output_directory/assignments.out" >&2
    exit 1
fi
for fixture in invalid-tail invalid-branch invalid-lambda; do
    output="$output_directory/assignment-$fixture"
    rm -f "$output"
    set +e
    "$compiler" build "$assignments/$fixture.ab" -o "$output" --no-cache \
        >"$output.out" 2>"$output.err"
    result=$?
    set -e
    if [[ $result -ne 1 ]] || ! grep -Fq 'ownership.assignment-value' "$output.err" ||
        ! grep -Fq 'help: ' "$output.err"; then
        echo "affine move: $fixture was not rejected with ownership.assignment-value" >&2
        sed -n '1,20p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]] || exit 1
done

echo "affine resources: own/var borrows + mode-bearing callables + FnOnce + partial places + recursive drops + CFG + compile-time/LLVM passed"
