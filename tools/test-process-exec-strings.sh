#!/usr/bin/env bash
# The strings a forked child execs with (#829): the executable found on PATH, the working directory and the
# redirect paths were nativeCStringAddress copies on the collected heap, held only by their numbers, so a
# collection in the allocations before the fork (the argument and environment vectors) freed them and the child
# exec'd "" or "0" (exit 127). It showed under `#`, in the compiler's busier heap, as process-capture and
# linux-process returning 0. tests/cases/process-exec-strings collects at every allocation and starts a child
# each way abla/process does, release and --fast; it must exit 42.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/process-exec-strings"
rm -rf "$output_directory"
mkdir -p "$output_directory"

case $(uname -s) in
    Linux) ;;
    *) echo "process exec strings: not Linux, skipped"; exit 0 ;;
esac

for mode in release fast; do
    flags=()
    [[ $mode == release ]] || flags=(--fast)
    "$compiler" build "$project_root/tests/cases/process-exec-strings/main.ab" -o "$output_directory/main-$mode" \
        --no-cache "${flags[@]}" > "$output_directory/main-$mode.log" 2>&1 ||
        { echo "process exec strings: did not build ($mode)" >&2; cat "$output_directory/main-$mode.log" >&2; exit 1; }
    status=0
    (cd "$project_root" && tools/run-limited.sh "$output_directory/main-$mode") || status=$?
    [[ $status == 42 ]] ||
        { echo "process exec strings: exited $status ($mode), not 42: the check that failed, numbered from 1" >&2; exit 1; }
done
echo "process exec strings: children exec what they were given, with a collection at every allocation"
