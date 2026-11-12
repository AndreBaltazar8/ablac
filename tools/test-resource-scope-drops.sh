#!/usr/bin/env bash
# Resource locals run drop() at the end of their scope (an inner block, then the
# function, latest declared first), whatever the length of their type's name.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/resource-scope-drops"
mkdir -p "$output_directory"

# ir_guard IR NAMES FORBIDDEN MAXSLOTS: see tools/llvm-define-guard.awk.
ir_guard() {
    awk -v names="$2" -v forbidden="$3" -v maxslots="$4" -f "$project_root/tools/llvm-define-guard.awk" "$1" "$1" \
        || { echo "resource scope drops: IR guard failed for $1" >&2; exit 1; }
}

"$compiler" build "$project_root/tests/cases/modules/resource-short-name-drop.ab" \
    -o "$output_directory/program"
output=$("$output_directory/program")
expected=$'inner 3\ndrop File 3\nwork 2 4\ndrop Files 4\ndrop Doc 2\ndrop A 1\ndone'
[[ $output == "$expected" ]] || { echo "unexpected output:"; echo "$output"; exit 1; }
echo "resource scope drops: every local's drop runs, short type names too"

for fixture in discarded-if unchanged-if discarded-joins discarded-secret-joins; do
    for profile in release fast; do
        arguments=(build "$project_root/tests/cases/bootstrap/$fixture.ab"
            -o "$output_directory/$fixture-$profile")
        [[ $profile != fast ]] || arguments+=(--fast)
        "$compiler" "${arguments[@]}"
        for stress in 0 1; do
            status=0
            ABLA_GC_STRESS=$stress "$output_directory/$fixture-$profile" || status=$?
            [[ $status == 42 ]] || {
                echo "$fixture ($profile, GC stress $stress): exit $status"
                exit 1
            }
        done
    done
done

# The golden transcript was also checked against the compiler before effect-only
# lowering: inner cleanup, discarded result close, then the following statement.
for profile in release fast o1; do
    arguments=(build "$project_root/tests/cases/bootstrap/discarded-close-order.ab"
        -o "$output_directory/close-$profile")
    case "$profile" in fast) arguments+=(--fast);; o1) arguments+=(--o1);; esac
    "$compiler" "${arguments[@]}"
    for stress in 0 1; do
        ABLA_GC_STRESS=$stress "$output_directory/close-$profile" > "$output_directory/close.out"
        cmp "$project_root/tests/cases/bootstrap/discarded-close-order.out" "$output_directory/close.out"
    done
done

"$compiler" --emit-llvm "$project_root/tests/cases/bootstrap/discarded-secret-joins.ab" \
    > "$output_directory/discarded-secret-joins.ll"
ir_guard "$output_directory/discarded-secret-joins.ll" 'discardedSecretIf discardedSecretWhen discardedSecretNested' '@abla_i64( %gc.block' -1

"$compiler" --emit-llvm "$project_root/tests/cases/bootstrap/discarded-if.ab" \
    > "$output_directory/discarded-if.ll"
ir_guard "$output_directory/discarded-if.ll" discardedIfScalar '' 1

"$compiler" --emit-llvm "$project_root/tests/cases/bootstrap/discarded-joins.ab" \
    > "$output_directory/discarded-joins.ll"
ir_guard "$output_directory/discarded-joins.ll" 'discardedJoinIf discardedJoinWhen' '' 1

echo "discarded if: arm drops, loop control, refinements and affine joins are preserved"
