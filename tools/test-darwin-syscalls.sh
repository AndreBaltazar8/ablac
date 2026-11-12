#!/usr/bin/env bash
# The calls a macOS program issues by BSD system call (#811, host.ab's
# __ablaRuntimeDarwinSyscall), exercised one by one through the portable surface:
# tests/cases/darwin-syscalls prints "name: ok (value)" per call and exits 7 when all
# are right. The same program runs on Linux, where the numbers are the kernel's, so
# a difference in the macOS job names the call. Usage: tools/test-darwin-syscalls.sh [compiler]
set -uo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/darwin-syscalls
mkdir -p "$out"
if ! "$compiler" build tests/cases/darwin-syscalls/main.ab -o "$out/main" --no-cache > "$out/build.log" 2>&1; then
    echo "darwin syscalls: the program did not build:" >&2
    cat "$out/build.log" >&2
    exit 1
fi
"$out/main" > "$out/run.out" 2> "$out/run.err"
status=$?
cat "$out/run.out"
if [[ -s $out/run.err ]]; then echo "stderr:"; cat "$out/run.err"; fi
if [[ $status -ne 7 ]] || grep -q FAIL "$out/run.out"; then
    echo "darwin syscalls: exit status $status (7 expected)" >&2
    exit 1
fi
echo 'darwin syscalls: every call agrees'
