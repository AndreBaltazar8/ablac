#!/usr/bin/env bash
# The runtime heap's allocator (stdlib/abla/runtime/platform/host.ab; #806 step 5): sizes 0 to 4096 and
# large, aligned, disjoint, calloc zeroing, realloc growth and shrink, large blocks unmapped when freed,
# and four threads allocating and freeing at once. Built release and --fast.
set -euo pipefail
compiler=${1:-build/ablac}
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out="$project_root/build/heap-allocator"
mkdir -p "$out"
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build "$project_root/tests/cases/heap-allocator/main.ab" -o "$out/main.$mode" "${flags[@]}"
    result=$("$project_root/tools/run-limited.sh" "$out/main.$mode") || {
        echo "heap allocator ($mode): $result" >&2
        exit 1
    }
    [[ $result == 'heap allocator ok' ]] || { echo "heap allocator ($mode): '$result'" >&2; exit 1; }
done
echo 'heap allocator ok'
