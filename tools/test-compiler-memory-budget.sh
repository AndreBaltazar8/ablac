#!/usr/bin/env bash
# The compiler's memory budget (ABLA_MAX_MEMORY_MB, which its launcher always sets)
# stays a hard cap now that the compiler also collects by its own growth step under
# it: a build that needs more stops with the limit's panic, not some other failure.
# And it stops soon: near the cap, pressure collection doesn't run at every
# allocating call (a 64 MB budget used to keep a build collecting for over an hour).
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/compiler-memory-budget"
mkdir -p "$output_directory"
for megabytes in 4 16 64; do
    set +e
    # (perl's alarm: a wall bound on macOS and Linux alike.)
    ABLA_MAX_MEMORY_MB=$megabytes perl -e 'alarm 60; exec @ARGV' \
        "$compiler" build "$project_root/src/orc_main.ab" \
        -o "$output_directory/compiler" --fast --no-cache \
        > "$output_directory/build.out" 2> "$output_directory/build.err"
    status=$?
    set -e
    if [[ $status -ne 101 ]] || ! grep -Fq 'panic: memory limit exceeded' "$output_directory/build.err"; then
        echo "compiler memory budget: a build over a $megabytes MB budget exited $status (142: still running after 60 s):" >&2
        sed -n '1,20p' "$output_directory/build.err" >&2
        exit 1
    fi
done
echo "compiler memory budget: builds over 4, 16 and 64 MB budgets stop with the limit's panic within 60 s"
