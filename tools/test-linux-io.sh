#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
output_directory="$project_root/build/linux-io-test"
program="$output_directory/program"
mkdir -p "$output_directory"

"$compiler" build \
    "$project_root/tests/cases/modules/linux-io.ab" \
    -o "$program"

if nm --defined-only "$program" | awk '{print $3}' |
    rg -q '^ablaHost|^abla_host_|^abla_platform_'; then
    echo 'raw Linux I/O linked a project C platform symbol' >&2
    exit 1
fi

set +e
printf 'alpha\r\n\nbeta' | \
    ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$program" \
    > "$output_directory/stdout.txt" \
    2> "$output_directory/stderr.txt"
status=$?
set -e

[[ $status -eq 42 ]]
[[ $(<"$output_directory/stdout.txt") == 'alpha||beta' ]]
[[ $(<"$output_directory/stderr.txt") == 'linux-io-stderr' ]]

printf '%s\n' \
    'raw Linux I/O: poll + buffered CRLF/empty/unterminated lines + full writes'
