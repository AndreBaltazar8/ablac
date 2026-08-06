#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Darwin || $(uname -m) != x86_64 ]]; then
    printf '%s\n' 'macOS host test requires an x86_64 Darwin host' >&2
    exit 2
fi

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
    --fast --no-cache -o "$output_directory/block"
file "$output_directory/block" | grep -q 'Mach-O 64-bit executable x86_64'
expect_status_42 "$output_directory/block"

"$compiler" build "$project_root/tests/cases/modules/portable-io.ab" \
    --fast --no-cache -o "$output_directory/portable-io"
set +e
"$output_directory/portable-io" > "$output_directory/portable-io.txt"
io_status=$?
set -e
[[ $io_status -eq 42 ]]
printf 'Hello, world!\nportable io\n' > "$output_directory/portable-io.expected"
cmp "$output_directory/portable-io.expected" \
    "$output_directory/portable-io.txt"

"$compiler" build "$project_root/tests/cases/modules/filesystem.ab" \
    --fast --no-cache -o "$output_directory/filesystem"
expect_status_42 "$output_directory/filesystem"

"$compiler" build "$project_root/tests/cases/modules/process-capture.ab" \
    --fast --no-cache -o "$output_directory/process-capture"
expect_status_42 "$output_directory/process-capture"

expect_status_42 \
    "$compiler" run "$project_root/tests/cases/bootstrap/block.ab"

printf '%s\n' \
    'macOS host: Mach-O build, console, filesystem, process, and ORC paths passed'
