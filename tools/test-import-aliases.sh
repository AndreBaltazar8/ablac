#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $compiler != /* ]]; then compiler="$project_root/$compiler"; fi
output="$project_root/build/import-alias-tests"
mkdir -p -- "$output"

"$compiler" build \
    "$project_root/tests/cases/modules/import-aliases.ab" \
    -o "$output/program" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output/program"
status=$?
set -e
[[ $status -eq 42 ]]

# A target subparser is registered only during the staged module pass. Locals
# following its raw invocation must never leak into the preliminary module
# interface or collide across otherwise independent unqualified imports.
"$compiler" build \
    "$project_root/tests/cases/modules/subparser-discovery-locals.ab" \
    -o "$output/subparser-discovery-locals" --no-cache
set +e
"$project_root/tools/run-limited.sh" "$output/subparser-discovery-locals"
subparser_discovery_status=$?
set -e
[[ $subparser_discovery_status -eq 33 ]]

"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/import-aliases.ab" \
    > "$output/original.ll"
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/import-aliases-renamed.ab" \
    > "$output/renamed.ll"
rg '^define hidden void @abla_fn_' "$output/original.ll" >/dev/null
rg '^define internal .* @abla_fn_.*_direct\(' "$output/original.ll" \
    | sed -E 's/\(.*//' | sort > "$output/original-symbols"
rg '^define hidden void @abla_fn_' "$output/renamed.ll" >/dev/null
rg '^define internal .* @abla_fn_.*_direct\(' "$output/renamed.ll" \
    | sed -E 's/\(.*//' | sort > "$output/renamed-symbols"
cmp "$output/original-symbols" "$output/renamed-symbols"
[[ $(wc -l < "$output/original-symbols") -gt 2 ]]

check_invalid() {
    local fixture=$1
    local code=$2
    set +e
    "$compiler" --emit-llvm \
        "$project_root/tests/cases/modules/$fixture.ab" \
        > "$output/$fixture.ll" 2> "$output/$fixture.err"
    local invalid_status=$?
    set -e
    [[ $invalid_status -ne 0 ]]
    grep -q "error\[$code\]:" "$output/$fixture.err"
}

check_invalid invalid-import-alias-value E_IMPORT_ALIAS_USED_AS_VALUE
check_invalid invalid-import-alias-member E_IMPORT_ALIAS_MEMBER_UNKNOWN
check_invalid invalid-import-alias-duplicate E_IMPORT_ALIAS_DUPLICATE
check_invalid \
    invalid-import-alias-target-duplicate E_IMPORT_ALIAS_TARGET_DUPLICATE
check_invalid \
    invalid-import-unqualified-ambiguous E_IMPORT_UNQUALIFIED_AMBIGUOUS

set +e
"$compiler" --emit-llvm \
    "$project_root/tests/cases/modules/invalid-import-alias-transitive.ab" \
    > "$output/transitive.ll" 2> "$output/transitive.err"
transitive_status=$?
set -e
[[ $transitive_status -ne 0 ]]
grep -q 'identifier:privateLeft' "$output/transitive.err"

"$project_root/tools/test-generated-cross-module-diagnostics.sh" "$compiler"

printf '%s\n' \
    'import aliases: qualified values/calls/types + isolation + canonical identities + diagnostics passed'
