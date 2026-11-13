#!/usr/bin/env bash
# The calls a macOS program issues by BSD system call (#811, host.ab's
# __ablaRuntimeDarwinSyscall), exercised one by one through the portable surface:
# each program of tests/cases/darwin-syscalls prints "name: ok (value)" per call and exits 7
# when all are right: main.ab (files and descriptors), sockets.ab (sockets), process.ab (fork, execve, wait4, kill, setpgid), kqueue.ab (epoll
# on kqueue), translate.ab (the pure translations of the socket layer, no system call). The
# same programs run on Linux, where the numbers are the kernel's, so a difference in the macOS
# job names the call. Usage: tools/test-darwin-syscalls.sh [compiler]
set -uo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/darwin-syscalls
mkdir -p "$out"
failed=0
for program in main sockets kqueue process signals translate; do
    if ! "$compiler" build "tests/cases/darwin-syscalls/$program.ab" -o "$out/$program" --no-cache > "$out/$program.build.log" 2>&1; then
        echo "darwin syscalls: $program did not build:" >&2
        cat "$out/$program.build.log" >&2
        exit 1
    fi
    "$out/$program" > "$out/$program.out" 2> "$out/$program.err"
    status=$?
    echo "== $program"
    cat "$out/$program.out"
    if [[ -s $out/$program.err ]]; then echo "stderr:"; cat "$out/$program.err"; fi
    if [[ $status -ne 7 ]] || grep -q FAIL "$out/$program.out"; then
        echo "darwin syscalls: $program: exit status $status (7 expected)" >&2
        failed=1
    fi
done
# The fault handlers (#811 group 6): the alternate stack, sigaction and the program's own
# trampoline. A deliberate stack overflow must print the guard's report and exit 101; a
# SIGSEGV that is no overflow must end the process by the signal (139); a debug build
# reports the stack too. Each check names itself.
for flags in "" "-g"; do
    if ! "$compiler" build tests/cases/runtime-checks/stack.ab -o "$out/stack" --no-cache $flags > "$out/stack.build.log" 2>&1; then
        echo "darwin syscalls: stack$flags did not build:" >&2; cat "$out/stack.build.log" >&2; exit 1
    fi
    "$out/stack" overflow > /dev/null 2> "$out/stack-overflow.err"; overflow=$?
    { "$out/stack" segv > /dev/null 2> "$out/stack-segv.err"; } 2> /dev/null; segv=$?
    if [[ $overflow -eq 101 ]] && grep -qx 'panic: stack overflow' "$out/stack-overflow.err"; then
        echo "fault stack overflow$flags: ok"
    else
        echo "darwin syscalls: stack overflow$flags: exit $overflow (101 expected): $(head -3 "$out/stack-overflow.err")" >&2; failed=1
    fi
    if [[ $segv -eq 139 ]] && ! grep -q 'stack overflow' "$out/stack-segv.err"; then
        echo "fault segv$flags: ok"
    else
        echo "darwin syscalls: segv$flags: exit $segv (139 expected)" >&2; failed=1
    fi
done
[[ $failed -eq 0 ]] || exit 1
echo 'darwin syscalls: every call agrees'
