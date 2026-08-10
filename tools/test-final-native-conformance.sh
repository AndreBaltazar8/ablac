#!/usr/bin/env bash
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/final-native-conformance"
build_memory_mb=${ABLA_CONFORMANCE_BUILD_MEMORY_MB:-4096}
build_seconds=${ABLA_CONFORMANCE_BUILD_SECONDS:-300}
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
    runtime-json:42
    html-subparser:42
    abla-subparser:42
    abla-subparser-builder:42
    abla-subparser-import:42
    module-frontend-subparser:42
    subparser-inferred-lambda:42
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
    bitwise:42
    crypto:42
    http-router:42
    types-valid:7
    compiler-reflection:42
    return-control:42
    defer:42
    concurrency:42
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
    delegated-bindings:42
    reactive-dependency-reflection:42
)

available_memory_mb=0
if [[ -r /proc/meminfo ]]; then
    while read -r memory_key memory_value memory_unit; do
        if [[ $memory_key == MemAvailable: ]]; then
            available_memory_mb=$((memory_value / 1024))
        fi
    done < /proc/meminfo
elif [[ $(uname -s) == Darwin ]]; then
    available_memory_mb=$(($(sysctl -n hw.memsize) / 1024 / 1024))
fi
processor_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1\n')
if [[ ! $build_memory_mb =~ ^[1-9][0-9]*$ ]]; then
    printf 'ABLA_CONFORMANCE_BUILD_MEMORY_MB must be a positive integer, got %q\n' \
        "$build_memory_mb" >&2
    exit 2
fi
if [[ ! $build_seconds =~ ^[1-9][0-9]*$ ]]; then
    printf 'ABLA_CONFORMANCE_BUILD_SECONDS must be a positive integer, got %q\n' \
        "$build_seconds" >&2
    exit 2
fi
jobs_by_memory=$((available_memory_mb / build_memory_mb))
(( jobs_by_memory > 0 )) || jobs_by_memory=1
default_jobs=$processor_count
(( default_jobs <= jobs_by_memory )) || default_jobs=$jobs_by_memory
(( default_jobs <= 8 )) || default_jobs=8
jobs=${ABLA_CONFORMANCE_JOBS:-$default_jobs}
if [[ ! $jobs =~ ^[1-9][0-9]*$ ]]; then
    printf 'ABLA_CONFORMANCE_JOBS must be a positive integer, got %q\n' \
        "$jobs" >&2
    exit 2
fi
(( jobs <= ${#fixtures[@]} )) || jobs=${#fixtures[@]}

run_fixture() {
    local fixture_specification=$1
    fixture=${fixture_specification%%:*}
    expected=${fixture_specification##*:}
    output="$output_directory/$fixture"
    error_log="$output_directory/$fixture.build-errors.txt"
    result_log="$output_directory/$fixture.result"
    : > "$result_log"

    if ! ABLA_MAX_MEMORY_MB=$build_memory_mb ABLA_MAX_SECONDS=$build_seconds \
        ABLA_MAX_CPU_SECONDS=$build_seconds \
        "$project_root/tools/run-limited.sh" \
        "$compiler" build \
        "$project_root/tests/cases/modules/$fixture.ab" \
        -o "$output" --no-cache 2>"$error_log"; then
        printf 'build-failed\n' > "$result_log"
        return 1
    fi

    set +e
    ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=20 ABLA_MAX_CPU_SECONDS=20 \
        "$project_root/tools/run-limited.sh" "$output"
    status=$?
    set -e
    if [[ $status -ne $expected ]]; then
        printf 'expected=%s actual=%s\n' "$expected" "$status" > "$result_log"
        return 1
    fi
    printf '%s\n' "$status" > "$result_log"
}
export -f run_fixture
export compiler project_root output_directory build_memory_mb build_seconds

printf 'final-native conformance: building %s programs with %s parallel job(s)\n' \
    "${#fixtures[@]}" "$jobs"
if ! printf '%s\0' "${fixtures[@]}" | \
    xargs -0 -n 1 -P "$jobs" bash -c 'run_fixture "$1"' _; then
    for fixture_specification in "${fixtures[@]}"; do
        fixture=${fixture_specification%%:*}
        result_log="$output_directory/$fixture.result"
        result=""
        if [[ -s $result_log ]]; then result=$(<"$result_log"); fi
        if [[ ! $result =~ ^[0-9]+$ ]]; then
            printf '%s: final-native conformance failed (%s)\n' \
                "$fixture" "$result" >&2
            sed -n '1,80p' \
                "$output_directory/$fixture.build-errors.txt" >&2
        fi
    done
    exit 1
fi

for fixture_specification in "${fixtures[@]}"; do
    fixture=${fixture_specification%%:*}
    status=$(<"$output_directory/$fixture.result")
    printf '%-32s %s\n' "$fixture" "$status"
done

echo "final-native conformance: ${#fixtures[@]} bounded programs passed"
