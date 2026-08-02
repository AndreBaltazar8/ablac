#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/final-native-conformance"
build_memory_mb=${ABLA_CONFORMANCE_BUILD_MEMORY_MB:-4096}
mkdir -p "$output_directory"

# These exercise staged evaluation, nested subparsers, nominal types, lambda
# calls, the emitted value runtime, and each currently exposed host module.
# Non-42 results are intentional where a fixture makes another value visible.
fixtures=(
    vm:135
    compile-time:40
    compile-compound:35
    compile-shared:42
    collections:42
    json-subparser:42
    html-subparser:42
    abla-subparser:42
    abla-subparser-builder:42
    abla-subparser-import:42
    module-frontend-subparser:42
    bootstrap-lexer:42
    bootstrap-parser:42
    bootstrap-sema:42
    bootstrap-ir:42
    bootstrap-cfg:42
    bootstrap-block:42
    bootstrap-collections:42
    bootstrap-objects:42
    classes:42
    stdlib:11
    strings-runtime:42
    string-rope:42
    host-runtime:42
    filesystem:42
    linux-filesystem:42
    linux-net:42
    process-capture:42
    memory-region:42
    bytes:42
    http-router:42
    types-valid:7
    compiler-reflection:42
    return-control:42
    loop-control:42
    for-range:42
    definite-assignment:42
    unsafe-boundary:42
    affine-move:42
    managed-mutable-views:42
    managed-alias-lifetimes:42
    stored-reference-lifetimes:42
    managed-result-freshness:42
    interior-cell:42
    nullable-refinement:42
    shared-ownership:42
    borrow-lifetimes:42
    scoped-region:42
    exhaustive-when:42
)

for fixture_specification in "${fixtures[@]}"; do
    fixture=${fixture_specification%%:*}
    expected=${fixture_specification##*:}
    output="$output_directory/$fixture"
    error_log="$output_directory/$fixture.build-errors.txt"

    if ! ABLA_MAX_MEMORY_MB=$build_memory_mb ABLA_MAX_SECONDS=90 \
        ABLA_MAX_CPU_SECONDS=90 \
        "$project_root/tools/run-limited.sh" \
        "$compiler" build \
        "$project_root/tests/cases/modules/$fixture.ab" \
        -o "$output" --no-cache 2>"$error_log"; then
        echo "$fixture: final-native build failed" >&2
        sed -n '1,80p' "$error_log" >&2
        exit 1
    fi

    set +e
    ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=20 ABLA_MAX_CPU_SECONDS=20 \
        "$project_root/tools/run-limited.sh" "$output"
    status=$?
    set -e
    if [[ $status -ne $expected ]]; then
        echo "$fixture: expected $expected, got $status" >&2
        exit 1
    fi
    printf '%-32s %s\n' "$fixture" "$status"
done

echo "final-native conformance: ${#fixtures[@]} bounded programs passed"
