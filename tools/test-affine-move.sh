#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/affine-move"
mkdir -p "$output_directory"
c_differential_compiler=${ABLA_C_DIFFERENTIAL_COMPILER:-}

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

if [[ -n $c_differential_compiler ]]; then
    "$c_differential_compiler" \
        "$project_root/tests/cases/modules/owned-parameters.ab" \
        > "$output_directory/owned-parameters.c"
    clang -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
        -I"$project_root/runtime" \
        "$output_directory/owned-parameters.c" \
        "$project_root/runtime/abla_runtime.c" \
        "$project_root/runtime/abla_runtime_host.c" \
        -o "$output_directory/owned-parameters-c"
    set +e
    "$project_root/tools/run-limited.sh" "$output_directory/owned-parameters-c"
    owned_c_status=$?
    set -e
    if [[ $owned_c_status -ne 42 ]]; then
        echo "affine move: C owned parameters expected 42, got $owned_c_status" >&2
        exit 1
    fi
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

if [[ -n $c_differential_compiler ]]; then
    "$c_differential_compiler" \
        "$project_root/tests/cases/modules/mutable-borrows.ab" \
        > "$output_directory/mutable-borrows.c"
    clang -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
        -I"$project_root/runtime" \
        "$output_directory/mutable-borrows.c" \
        "$project_root/runtime/abla_runtime.c" \
        "$project_root/runtime/abla_runtime_host.c" \
        -o "$output_directory/mutable-borrows-c"
    set +e
    "$project_root/tools/run-limited.sh" "$output_directory/mutable-borrows-c"
    mutable_c_status=$?
    set -e
    if [[ $mutable_c_status -ne 42 ]]; then
        echo "affine move: C mutable borrows expected 42, got $mutable_c_status" >&2
        exit 1
    fi
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

for fixture in \
    invalid-use-after-move \
    invalid-conditional-move \
    invalid-double-move \
    invalid-managed-alias-active-mutation \
    invalid-stored-reference-active-mutation \
    invalid-compile-stored-reference-active-mutation \
    invalid-transitive-managed-alias-active-mutation \
    invalid-compile-transitive-managed-alias-active-mutation \
    invalid-compile-managed-alias-active-mutation; do
    output="$output_directory/$fixture"
    rm -f "$output"
    set +e
    "$compiler" build "$project_root/tests/cases/bootstrap/$fixture.ab" \
        -o "$output" >"$output.out" 2>"$output.err"
    result=$?
    set -e
    if [[ $result -ne 1 ]] || ! grep -Fq 'ir.verification:' "$output.err"; then
        echo "affine move: $fixture was not rejected by CFG ownership" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]]
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
    invalid-managed-return-parameter \
    invalid-managed-return-this \
    invalid-managed-return-global \
    invalid-managed-return-stored-global \
    invalid-managed-alias-mutable-local \
    invalid-managed-alias-mutation \
    invalid-managed-alias-escape \
    invalid-stored-reference-escape \
    invalid-stored-reference-multiple \
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
    [[ ! -e $output ]]
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
    [[ ! -e $output ]]
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
[[ ! -e $output ]]

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
[[ ! -e $output ]]

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
    [[ ! -e $output ]]
done


output="$output_directory/invalid-owned-use-after-move"
rm -f "$output"
set +e
"$compiler" build \
    "$project_root/tests/cases/bootstrap/invalid-owned-use-after-move.ab" \
    -o "$output" >"$output.out" 2>"$output.err"
result=$?
set -e
if [[ $result -ne 1 ]] || ! grep -Fq 'ir.verification:' "$output.err"; then
    echo "affine move: moved owned parameter remained readable" >&2
    sed -n '1,80p' "$output.err" >&2
    exit 1
fi
[[ ! -e $output ]]

for fixture in \
    invalid-capture-use-after-move \
    invalid-once-closure-second-call \
    invalid-field-owner-after-move \
    invalid-index-owner-after-move \
    invalid-partial-owner-use \
    invalid-partial-reinitialize-branch \
    invalid-dynamic-place-reinitialize; do
    output="$output_directory/$fixture"
    rm -f "$output"
    set +e
    "$compiler" build "$project_root/tests/cases/bootstrap/$fixture.ab" \
        -o "$output" >"$output.out" 2>"$output.err"
    result=$?
    set -e
    if [[ $result -ne 1 ]] || ! grep -Fq 'ir.verification:' "$output.err"; then
        echo "affine move: $fixture escaped FnOnce CFG checks" >&2
        sed -n '1,80p' "$output.err" >&2
        exit 1
    fi
    [[ ! -e $output ]]
done

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
[[ ! -e $output ]]

"$compiler" build \
    "$project_root/tests/cases/modules/affine-move-c-backend.ab" \
    -o "$output_directory/c-generator" --no-cache
"$project_root/tools/run-limited.sh" "$output_directory/c-generator" \
    >"$output_directory/program.c"
clang -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
    -I"$project_root/runtime" \
    "$output_directory/program.c" \
    "$project_root/runtime/abla_runtime.c" \
    "$project_root/runtime/abla_runtime_host.c" \
    -o "$output_directory/c-program"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/c-program"
c_status=$?
set -e
if [[ $c_status -ne 42 ]]; then
    echo "affine move: C backend expected 42, got $c_status" >&2
    exit 1
fi

if [[ -n $c_differential_compiler ]]; then
"$c_differential_compiler" \
    "$project_root/tests/cases/modules/resource-lambda-capture.ab" \
    > "$output_directory/resource-lambda-capture.c"
clang -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
    -I"$project_root/runtime" \
    "$output_directory/resource-lambda-capture.c" \
    "$project_root/runtime/abla_runtime.c" \
    "$project_root/runtime/abla_runtime_host.c" \
    -o "$output_directory/resource-lambda-capture-c"
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/resource-lambda-capture-c"
capture_c_status=$?
set -e
if [[ $capture_c_status -ne 42 ]]; then
    echo "affine move: C owning lambda expected 42, got $capture_c_status" >&2
    exit 1
fi

"$c_differential_compiler" \
    "$project_root/tests/cases/modules/resource-lambda-drop.ab" \
    > "$output_directory/resource-lambda-drop.c"
clang -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
    -I"$project_root/runtime" \
    "$output_directory/resource-lambda-drop.c" \
    "$project_root/runtime/abla_runtime.c" \
    "$project_root/runtime/abla_runtime_host.c" \
    -o "$output_directory/resource-lambda-drop-c"
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/resource-lambda-drop-c"
lambda_drop_c_status=$?
set -e
if [[ $lambda_drop_c_status -ne 42 ]]; then
    echo "affine move: C FnOnce environment drops expected 42, got $lambda_drop_c_status" >&2
    exit 1
fi

"$c_differential_compiler" \
    "$project_root/tests/cases/modules/place-move.ab" \
    > "$output_directory/place-move.c"
clang -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
    -I"$project_root/runtime" \
    "$output_directory/place-move.c" \
    "$project_root/runtime/abla_runtime.c" \
    "$project_root/runtime/abla_runtime_host.c" \
    -o "$output_directory/place-move-c"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/place-move-c"
place_c_status=$?
set -e
if [[ $place_c_status -ne 42 ]]; then
    echo "affine move: C field/index moves expected 42, got $place_c_status" >&2
    exit 1
fi

"$c_differential_compiler" \
    "$project_root/tests/cases/modules/resource-drop.ab" \
    > "$output_directory/resource-drop.c"
clang -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
    -I"$project_root/runtime" \
    "$output_directory/resource-drop.c" \
    "$project_root/runtime/abla_runtime.c" \
    "$project_root/runtime/abla_runtime_host.c" \
    -o "$output_directory/resource-drop-c"
set +e
"$project_root/tools/run-limited.sh" "$output_directory/resource-drop-c"
drop_c_status=$?
set -e
if [[ $drop_c_status -ne 42 ]]; then
    echo "affine move: C deterministic drops expected 42, got $drop_c_status" >&2
    exit 1
fi

"$c_differential_compiler" \
    "$project_root/tests/cases/modules/resource-structural-drop.ab" \
    > "$output_directory/resource-structural-drop.c"
clang -std=c11 -Wall -Wextra -Wpedantic -Wconversion -Werror \
    -I"$project_root/runtime" \
    "$output_directory/resource-structural-drop.c" \
    "$project_root/runtime/abla_runtime.c" \
    "$project_root/runtime/abla_runtime_host.c" \
    -o "$output_directory/resource-structural-drop-c"
set +e
"$project_root/tools/run-limited.sh" \
    "$output_directory/resource-structural-drop-c"
structural_drop_c_status=$?
set -e
if [[ $structural_drop_c_status -ne 42 ]]; then
    echo "affine move: C structural drops expected 42, got $structural_drop_c_status" >&2
    exit 1
fi
fi

echo "affine resources: own/var borrows + mode-bearing callables + FnOnce + partial places + recursive drops + CFG + compile-time/LLVM/C passed"
