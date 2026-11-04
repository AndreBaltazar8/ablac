#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Darwin ]]; then
    printf '%s\n' 'macOS host test requires a Darwin host' >&2
    exit 2
fi

case "$(uname -m)" in
    x86_64) expected_architecture=x86_64 ;;
    arm64) expected_architecture=arm64 ;;
    *)
        printf 'unsupported macOS test architecture: %s\n' "$(uname -m)" >&2
        exit 2
        ;;
esac

compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/macos-host-test"
mkdir -p "$output_directory"

expect_status_42() {
    set +e
    "$@"
    local status=$?
    set -e
    if [[ $status -ne 42 ]]; then
        printf 'macOS host test: expected status 42, got %s: %s\n' \
            "$status" "$*" >&2
        exit 1
    fi
}

"$compiler" build "$project_root/tests/cases/bootstrap/block.ab" \
    --fast -o "$output_directory/block"
file "$output_directory/block" |
    grep -q "Mach-O 64-bit executable $expected_architecture"
expect_status_42 "$output_directory/block"

"$compiler" build "$project_root/tests/cases/modules/portable-io.ab" \
    --fast -o "$output_directory/portable-io"
set +e
"$output_directory/portable-io" > "$output_directory/portable-io.txt"
io_status=$?
set -e
[[ $io_status -eq 42 ]] || exit 1
printf 'Hello, world!\nportable io\n' > "$output_directory/portable-io.expected"
cmp "$output_directory/portable-io.expected" \
    "$output_directory/portable-io.txt"

"$compiler" build "$project_root/tests/cases/unix-stream/main.ab" \
    --fast -o "$output_directory/unix-stream"
expect_status_42 "$output_directory/unix-stream"

"$compiler" build "$project_root/tests/cases/uuid/main.ab" \
    --fast -o "$output_directory/uuid"
expect_status_42 "$output_directory/uuid"

"$compiler" build "$project_root/tests/cases/modules/filesystem.ab" \
    --fast -o "$output_directory/filesystem"
expect_status_42 "$output_directory/filesystem"

"$compiler" build "$project_root/tests/cases/path-home/main.ab" \
    --fast -o "$output_directory/path-home"
HOME='/tmp/abla test home' ABLA_EXPECT_HOME='/tmp/abla test home' "$output_directory/path-home"
env -u HOME ABLA_EXPECT_HOME='<none>' "$output_directory/path-home"
HOME='' ABLA_EXPECT_HOME='<none>' "$output_directory/path-home"

"$compiler" build "$project_root/tests/cases/process-pipeline/main.ab" \
    --fast -o "$output_directory/pipeline"
"$output_directory/pipeline"
"$compiler" build "$project_root/tests/cases/process-pipeline/groups.ab" \
    --fast -o "$output_directory/pipeline-groups"
ABLA_GROUP_TEST_FILE="$output_directory/pipeline-group.txt" "$output_directory/pipeline-groups"

"$compiler" build "$project_root/tests/cases/modules/process-capture.ab" \
    --fast -o "$output_directory/process-capture"
expect_status_42 "$output_directory/process-capture"

expect_status_42 \
    "$compiler" run --jit "$project_root/tests/cases/bootstrap/block.ab"

printf '%s\n' \
    'macOS host: Mach-O build, console, filesystem, process, and ORC paths passed'
