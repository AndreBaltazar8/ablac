#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    printf 'usage: %s <self-hosted-compiler>\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=$1
directory="$project_root/build/libc-free-target"
program="$directory/program"
mkdir -p "$directory"

"$compiler" build \
    "$project_root/tests/cases/modules/libc-free-linux.ab" \
    --fast --no-cache --target x86_64-linux-raw -o "$program"

if [[ -n $(nm -u "$program") ]]; then
    echo 'libc-free target left undefined symbols in the executable' >&2
    nm -u "$program" >&2
    exit 1
fi
if readelf -l "$program" | rg -q 'INTERP'; then
    echo 'libc-free target contains an ELF interpreter' >&2
    exit 1
fi
if readelf -d "$program" 2>&1 | rg -q 'NEEDED'; then
    echo 'libc-free target contains a dynamic dependency' >&2
    exit 1
fi
if nm --defined-only "$program" | awk '{print $3}' |
    rg -q '^ablaHost|^abla_host_|^abla_checked_'; then
    echo 'libc-free target linked a project host capability symbol' >&2
    exit 1
fi

set +e
ABLA_MAX_MEMORY_MB=128 ABLA_MAX_SECONDS=10 \
    "$project_root/tools/run-limited.sh" "$program" verified \
    > "$directory/output.txt"
status=$?
set -e
[[ $status -eq 42 ]]
printf 'libc-free abla\n' > "$directory/expected.txt"
cmp "$directory/expected.txt" "$directory/output.txt"

set +e
"$compiler" build "$project_root/tests/cases/modules/host-runtime.ab" \
    --fast --no-cache --target x86_64-linux-raw \
    -o "$directory/invalid" > "$directory/invalid.out" \
    2> "$directory/invalid.err"
invalid_status=$?
set -e
[[ $invalid_status -ne 0 ]]
rg -q 'target x86_64-linux-raw does not permit hosted or LLVM runtime imports' \
    "$directory/invalid.err"

printf '%s\n' \
    'libc-free target: raw startup + mmap allocator + memory primitives + portable I/O + host rejection passed'
