#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $compiler != /* ]]; then compiler="$project_root/$compiler"; fi
output="$project_root/build/contract-import-tests"
mkdir -p -- "$output"

"$compiler" build \
    "$project_root/tests/cases/modules/contract-import.ab" \
    -o "$output/contract-program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output/contract-program"
status=$?
set -e
[[ $status -eq 42 ]]

"$compiler" build \
    "$project_root/tests/cases/modules/contract-effect-import.ab" \
    -o "$output/effect-program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output/effect-program"
status=$?
set -e
[[ $status -eq 42 ]]

"$compiler" build \
    "$project_root/tests/cases/modules/contract-import-ordinary.ab" \
    -o "$output/ordinary-program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output/ordinary-program"
status=$?
set -e
[[ $status -eq 42 ]]

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-contract-call-unconsumed.ab" \
    > "$output/unconsumed.ll" 2> "$output/unconsumed.err"
invalid_status=$?
set -e
[[ $invalid_status -ne 0 ]]
grep -q 'error\[E_CONTRACT_CALL_NOT_CONSUMED\]:' \
    "$output/unconsumed.err"
grep -q 'remoteIncrement' "$output/unconsumed.err"
grep -q '0 IR' "$output/unconsumed.err"

temporary=$(mktemp -d "$output/cache-identity.XXXXXX")
trap 'rm -rf -- "$temporary"' EXIT
cp "$project_root/tests/cases/modules/contract-import.ab" "$temporary/root.ab"
cp "$project_root/tests/cases/modules/contract-provider.ab" "$temporary/provider.ab"
cp "$project_root/tests/cases/modules/contract-backend.ab" "$temporary/backend.ab"
cp "$project_root/tests/cases/modules/contract-server-support.ab" \
    "$temporary/support.ab"
perl -pi -e \
    's/contract-provider\.ab/provider.ab/; s/contract-backend\.ab/backend.ab/' \
    "$temporary/root.ab"
perl -pi -e 's/contract-server-support\.ab/support.ab/' \
    "$temporary/backend.ab"
"$compiler" --emit-llvm "$temporary/root.ab" > "$temporary/before.ll"
perl -pi -e 's/serverAdd\(value, bonus\)/serverAdd(value + 0, bonus)/' \
    "$temporary/backend.ab"
"$compiler" --emit-llvm "$temporary/root.ab" > "$temporary/after.ll"
cmp "$temporary/before.ll" "$temporary/after.ll"
! grep -Eq 'contract:|remoteIncrement|serverAdd|serverRuntimeState' \
    "$temporary/before.ll"
perl -pi -e 's/\@rpc/\@changedContract/' "$temporary/backend.ab"
"$compiler" --emit-llvm "$temporary/root.ab" > "$temporary/changed.ll"
! cmp -s "$temporary/before.ll" "$temporary/changed.ll"

printf '%s\n' \
    'contract imports: typed consumption + implementation isolation + stable body cache identity + rejection passed'
