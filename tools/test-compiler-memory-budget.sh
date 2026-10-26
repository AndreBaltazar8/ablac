#!/usr/bin/env bash
# The compiler's memory budget (ABLA_MAX_MEMORY_MB, which its launcher always sets)
# stays a hard cap now that the compiler also collects by its own growth step under
# it: a build that needs more stops with the limit's panic, not some other failure.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/compiler-memory-budget"
mkdir -p "$output_directory"
set +e
ABLA_MAX_MEMORY_MB=4 "$compiler" build "$project_root/src/orc_main.ab" \
    -o "$output_directory/compiler" --fast --no-cache \
    > "$output_directory/build.out" 2> "$output_directory/build.err"
status=$?
set -e
if [[ $status -ne 101 ]] || ! grep -Fq 'panic: memory limit exceeded' "$output_directory/build.err"; then
    echo "compiler memory budget: a build over a 4 MB budget exited $status:" >&2
    sed -n '1,20p' "$output_directory/build.err" >&2
    exit 1
fi
echo "compiler memory budget: a build over the budget stops with the limit's panic"
