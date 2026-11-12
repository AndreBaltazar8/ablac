#!/usr/bin/env bash
# Raw system calls: a failure is -errno, six arguments reach the kernel (#806: on
# x86-64 Linux an inline `syscall` instruction, no libc syscall() or errno).
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
if [[ $(uname -s) != Linux ]]; then echo 'linux syscall: Linux only'; exit 0; fi
out="$root/build/linux-syscall"
mkdir -p "$out"
cd "$root"
for mode in "" --fast; do
    # shellcheck disable=SC2086
    "$compiler" build tests/cases/linux-syscall/main.ab -o "$out/program" --no-cache $mode
    status=0
    "$out/program" || status=$?
    [[ $status -eq 42 ]] || { echo "linux syscall ${mode:-release}: returned $status" >&2; exit 1; }
done
# On x86-64 Linux neither libc's syscall() nor its errno may be imported.
if [[ $(uname -m) == x86_64 ]] && nm -D --undefined-only "$out/program" | awk '{ print $NF }' | grep -qE '^(syscall|__errno_location)(@|$)'; then
    echo 'linux syscall: the program still imports syscall or __errno_location' >&2
    exit 1
fi
"$compiler" build tests/cases/linux-syscall/owns-runtime.ab -o "$out/owns-runtime" --no-cache
status=0
"$out/owns-runtime" || status=$?
[[ $status -eq 42 ]] || { echo "linux syscall: ablaHostOwnsRuntime returned $status" >&2; exit 1; }
echo 'linux syscall: -errno results, six arguments and no libc syscall/errno passed'
