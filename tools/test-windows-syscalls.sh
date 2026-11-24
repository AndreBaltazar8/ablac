#!/usr/bin/env bash
# The Linux system calls the Windows runtime translates (W1c, stdlib/abla/runtime/platform/windows/entry.ab):
#   - the list `__ablaRuntimeWindowsTranslated` says is exactly the set of numbers `__ablaRuntimeWindowsSyscall` tests (a call added
#     to the translation without the list, or the list without the call, fails here);
#   - a number outside the set is refused, not answered with a quiet success: a program that makes call 999 ends with status 70
#     and names the number on standard error (under Wine, skipped with a message when Wine is not installed).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
file=stdlib/abla/runtime/platform/windows/entry.ab
out=build/windows-syscalls
rm -rf "$out"
mkdir -p "$out"
fail() { echo "windows-syscalls: $1" >&2; exit 1; }
tested=$(grep -oE 'number == [0-9]+' "$file" | grep -oE '[0-9]+' | sort -n | uniq | tr '\n' ' ')
listed=$(grep -E '^trusted fun __ablaRuntimeWindowsTranslated' "$file" | grep -oE '"[0-9 ]+"' | tr -d '"' | tr ' ' '\n' | sort -n | tr '\n' ' ')
[[ -n $tested ]] || fail "no numbers found in __ablaRuntimeWindowsSyscall"
[[ $tested == "$listed" ]] || fail "__ablaRuntimeWindowsTranslated lists [$listed] but the translation tests [$tested]"
for tool in lld-link llvm-readobj; do
    command -v "$tool" > /dev/null || { echo "windows-syscalls: the list matches ($tested); the refusal is skipped ($tool is not installed)"; exit 0; }
done
"$compiler" build tests/cases/windows/refuse.ab --target x86_64-windows-hosted -o "$out/refuse.exe" --fast --no-cache > "$out/refuse.log" 2>&1 ||
    { cat "$out/refuse.log" >&2; fail "refuse.ab did not build for Windows"; }
status=0
tools/windows/wine-run.sh "$out/refuse.exe" > "$out/refuse.out" 2> "$out/refuse.err" || status=$?
if [[ $status == 125 ]]; then
    echo "windows-syscalls: the list matches ($tested); the refusal is skipped (Wine is not installed)"
    exit 0
fi
[[ $status == 70 ]] || fail "an untranslated call ended with status $status under Wine, not 70"
grep -q 'unsupported Linux system call 999' "$out/refuse.out" "$out/refuse.err" || fail "the refusal does not name the call"

# What the compiler asks before it reaches LLVM (self.ab): the stack limit is the 8 MiB the image is linked with, the descriptor
# limit the table's 4096, the affinity mask 8 bytes with a CPU in it, and /proc/self/exe the program itself ("/" for "\"). And
# what it links: a float `%` (the runtime's remainder: no fmod to import), malloc_trim (0) and pthread_key_create (ENOSYS).
"$compiler" build tests/cases/windows/self.ab --target x86_64-windows-hosted -o "$out/self.exe" --fast --no-cache > "$out/self.log" 2>&1 ||
    { cat "$out/self.log" >&2; fail "self.ab did not build for Windows"; }
status=0
tools/windows/wine-run.sh "$out/self.exe" > "$out/self.out" 2> "$out/self.err" || status=$?
[[ $status == 0 ]] || fail "self.exe exited $status: $(head -3 "$out/self.err")"
expect() { grep -qxE "$1" "$out/self.out" || fail "self.exe printed no line matching '$1': $(cat "$out/self.out" "$out/self.err")"; }
expect 'remainder 1\.5'
expect 'trim 0 key 38'
expect 'fchmod 0:292 0:420'
expect 'null true 0'
expect 'stack 8388608 8388608'
expect 'descriptors 4096'
expect 'affinity 8 bytes, some CPUs'
expect 'image [A-Za-z]:/([^\\]*/)?self\.exe'
expect 'image exists true'
expect 'cpu time true'
expect 'signal mask 0 0'
expect 'ids 0 0 0 0'
# The unwind-free jump pair (jump.ab): abla_setjmp returns 0 first, abla_longjmp from twenty frames down returns 7 to it.
"$compiler" build tests/cases/windows/jump.ab --target x86_64-windows-hosted -o "$out/jump.exe" --fast --no-cache > "$out/jump.log" 2>&1 ||
    { cat "$out/jump.log" >&2; fail "jump.ab did not build for Windows"; }
status=0
tools/windows/wine-run.sh "$out/jump.exe" > "$out/jump.out" 2> "$out/jump.err" || status=$?
[[ $status == 0 ]] || fail "jump.exe exited $status: $(head -3 "$out/jump.err")"
[[ "$(cat "$out/jump.out")" == $'armed\njumped 7' ]] || fail "jump.exe printed: $(cat "$out/jump.out" "$out/jump.err")"
# A fault sent back (fault-jump.ab): a vectored handler ahead of the runtime's redirects an access violation with
# abla_windows_redirect to abla_longjmp, and the thread is back where abla_setjmp armed it with 4, not ended by the fault.
"$compiler" build tests/cases/windows/fault-jump.ab --target x86_64-windows-hosted -o "$out/fault-jump.exe" --fast --no-cache \
    > "$out/fault-jump.log" 2>&1 || { cat "$out/fault-jump.log" >&2; fail "fault-jump.ab did not build for Windows"; }
status=0
tools/windows/wine-run.sh "$out/fault-jump.exe" > "$out/fault-jump.out" 2> "$out/fault-jump.err" || status=$?
[[ $status == 0 ]] || fail "fault-jump.exe exited $status: $(head -3 "$out/fault-jump.out" "$out/fault-jump.err")"
[[ "$(cat "$out/fault-jump.out")" == $'armed\nback with 4' ]] || fail "fault-jump.exe printed: $(cat "$out/fault-jump.out" "$out/fault-jump.err")"
# An interrupt word (interrupt.ab, §5): with the thread's word set, each wait returns EINTR (-4) within a slice: a 30-second
# nanosleep, poll with nothing to wait on, poll on a socket, a futex wait and wait4 on a child sleeping 30 s; cleared, the killed
# child is collected and a 50 ms sleep returns 0. The whole program takes seconds, not the minutes a missed interrupt would.
"$compiler" build tests/cases/windows/interrupt.ab --target x86_64-windows-hosted -o "$out/interrupt.exe" --fast --no-cache \
    > "$out/interrupt.log" 2>&1 || { cat "$out/interrupt.log" >&2; fail "interrupt.ab did not build for Windows"; }
status=0
started=$SECONDS
tools/windows/wine-run.sh "$out/interrupt.exe" > "$out/interrupt.out" 2> "$out/interrupt.err" || status=$?
[[ $status == 0 ]] || fail "interrupt.exe exited $status: $(head -3 "$out/interrupt.out" "$out/interrupt.err")"
[[ "$(cat "$out/interrupt.out")" == $'interrupted sleep -4\ninterrupted poll -4\ninterrupted socket poll -4\ninterrupted futex wait -4\ninterrupted wait4 -4\ncollected true\nplain sleep 0' ]] || fail "interrupt.exe printed: $(cat "$out/interrupt.out" "$out/interrupt.err")"
(( SECONDS - started < 25 )) || fail "interrupt.exe took $((SECONDS - started)) s: the interrupted sleep ran its time"
# The fault target (fault-guard.ab, call 4004, §4): an access violation in VirtualAlloc'd code and one in the program's own
# code each go to the target with SIGSEGV's number and the address touched, which jumps back with 4.
"$compiler" build tests/cases/windows/fault-guard.ab --target x86_64-windows-hosted -o "$out/fault-guard.exe" --fast --no-cache \
    > "$out/fault-guard.log" 2>&1 || { cat "$out/fault-guard.log" >&2; fail "fault-guard.ab did not build for Windows"; }
status=0
timeout 60 tools/windows/wine-run.sh "$out/fault-guard.exe" > "$out/fault-guard.out" 2> "$out/fault-guard.err" || status=$?
[[ $status == 0 ]] || fail "fault-guard.exe exited $status: $(head -5 "$out/fault-guard.out" "$out/fault-guard.err")"
[[ "$(cat "$out/fault-guard.out")" == $'armed 0, JIT fault back with 4, signal 11, address 16\nown fault back with 4, address 24\noverflow back with 4, signal 11\nsecond overflow back with 4, signal 11' ]] || fail "fault-guard.exe printed: $(cat "$out/fault-guard.out" "$out/fault-guard.err")"
# The vectored handler runs on the faulting thread's stack, an overflowed one included, so what it reaches there is held small:
# its entry (call 4005, as the watchdog's 4003) goes to __ablaRuntimeWindowsGuardSyscall, not to the system call dispatcher
# whose frame grows with every call it translates (under Wine it outgrew the overflowed stack once), and that function's frame
# (its x64 unwind codes: the allocation and the registers it pushes, with the handler inlined into it) stays within 128 bytes.
# Built -g, so the object names the function.
"$compiler" build tests/cases/windows/fault-guard.ab --target x86_64-windows-hosted -g -o "$out/fault-guard-named.exe" --no-cache \
    > "$out/fault-guard-named.log" 2>&1 || { cat "$out/fault-guard-named.log" >&2; fail "fault-guard.ab did not build with -g"; }
grep -q '@windows.__ablaRuntimeWindowsGuardSyscall(i64 4005,' "$out/fault-guard-named.exe.ll" ||
    fail "the vectored handler's entry does not call __ablaRuntimeWindowsGuardSyscall"
frame=$(llvm-readobj --unwind "$out/fault-guard-named.exe.o" | awk '
    /StartAddress: windows\.__ablaRuntimeWindowsGuardSyscall / { found = 1; inside = 1; next }
    /StartAddress:/ { inside = 0 }
    inside && /ALLOC_(SMALL|LARGE) size=/ { match($0, /size=[0-9]+/); size += substr($0, RSTART + 5, RLENGTH - 5) }
    inside && /PUSH_NONVOL/ { size += 8 }
    END { print found ? size : -1 }')
(( frame >= 0 )) || fail "no unwind data for __ablaRuntimeWindowsGuardSyscall in the -g object"
(( frame <= 128 )) || fail "__ablaRuntimeWindowsGuardSyscall's frame is $frame bytes, over the 128 the vectored handler may take"
# The runtime's watchdog (watchdog.ab, call 4002): armed for the calling thread, it redirects it out of executable memory from
# VirtualAlloc, never out of a loaded image (a runtime sleep gets EINTR instead), interrupts a deferred stop's sleep and an
# interpreted site's pipe read with EINTR, and does nothing once disarmed. The whole program takes seconds, not the 30-second
# sleeps a missed stop would.
"$compiler" build tests/cases/windows/watchdog.ab --target x86_64-windows-hosted -o "$out/watchdog.exe" --fast --no-cache \
    > "$out/watchdog.log" 2>&1 || { cat "$out/watchdog.log" >&2; fail "watchdog.ab did not build for Windows"; }
status=0
started=$SECONDS
timeout 120 tools/windows/wine-run.sh "$out/watchdog.exe" > "$out/watchdog.out" 2> "$out/watchdog.err" || status=$?
[[ $status == 0 ]] || fail "watchdog.exe exited $status: $(head -5 "$out/watchdog.out" "$out/watchdog.err")"
[[ "$(cat "$out/watchdog.out")" == $'armed 0\nspin back with 3\nruntime sleep -4\ndeferred sleep -4, asked true\ninterpreted read -4\ndisarmed sleep 0' ]] || fail "watchdog.exe printed: $(cat "$out/watchdog.out" "$out/watchdog.err")"
(( SECONDS - started < 25 )) || fail "watchdog.exe took $((SECONDS - started)) s: a stop was missed"
# The watchdog takes no lock the thread it suspended may hold (watchdog-loader.ab): armed with a 1 ms deadline while the thread
# takes and releases the loader lock 400000 times (GetModuleHandleW by name). Where its look at the program counter took the
# loader lock (RtlPcToFileHeader), the program never ended; it takes about a second.
"$compiler" build tests/cases/windows/watchdog-loader.ab --target x86_64-windows-hosted -o "$out/watchdog-loader.exe" --fast \
    --no-cache > "$out/watchdog-loader.log" 2>&1 || { cat "$out/watchdog-loader.log" >&2; fail "watchdog-loader.ab did not build for Windows"; }
status=0
timeout 60 tools/windows/wine-run.sh "$out/watchdog-loader.exe" > "$out/watchdog-loader.out" 2> "$out/watchdog-loader.err" ||
    status=$?
[[ $status == 0 ]] || fail "watchdog-loader.exe exited $status (124: the watchdog waited on the loader lock): $(head -5 "$out/watchdog-loader.out" "$out/watchdog-loader.err")"
[[ "$(cat "$out/watchdog-loader.out")" == $'armed 0\nfound 400000 of 400000, asked true' ]] || fail "watchdog-loader.exe printed: $(cat "$out/watchdog-loader.out" "$out/watchdog-loader.err")"
# The watchdog's two stops (preempt.ab, §5), each from a second thread: a thread spinning in VirtualAlloc'd code is suspended,
# its CONTEXT redirected to a jump back with 3, and resumed; a thread reading an empty pipe gets EINTR from CancelSynchronousIo.
"$compiler" build tests/cases/windows/preempt.ab --target x86_64-windows-hosted -o "$out/preempt.exe" --fast --no-cache \
    > "$out/preempt.log" 2>&1 || { cat "$out/preempt.log" >&2; fail "preempt.ab did not build for Windows"; }
status=0
timeout 60 tools/windows/wine-run.sh "$out/preempt.exe" > "$out/preempt.out" 2> "$out/preempt.err" || status=$?
[[ $status == 0 ]] || fail "preempt.exe exited $status: $(head -5 "$out/preempt.out" "$out/preempt.err")"
[[ "$(cat "$out/preempt.out")" == $'spinning\nback with 3, watchdog 1\ninterrupted pipe read -4\ncancelled true' ]] || fail "preempt.exe printed: $(cat "$out/preempt.out" "$out/preempt.err")"
# A failed Winsock call is a negative errno (socket-failure.ab): ws2_32 returns -1 as a 32-bit int, and read as 64 bits it was
# 4294967295, a count of bytes received that made httpAsyncPlainRead copy off the top of its stack on windows-latest.
# SO_RCVTIMEO is converted from the Linux timeval to Winsock's milliseconds (passed through, 1.5 s waited 1 ms), and a read it
# ends is EAGAIN. A peer's reset (SO_LINGER 0, close) makes read, readResult and a TLS session's read fail with ECONNRESET, and SO_LINGER is
# converted between Linux's two ints and Winsock's two words (a linger time above 0 reads back). A silent peer: a TcpConnection.readResult
# under its receive timeout waits it out and is EAGAIN with no bytes.
"$compiler" build tests/cases/windows/socket-failure.ab --target x86_64-windows-hosted -o "$out/socket-failure.exe" --fast \
    --no-cache > "$out/socket-failure.log" 2>&1 || { cat "$out/socket-failure.log" >&2; fail "socket-failure.ab did not build for Windows"; }
status=0
timeout 60 tools/windows/wine-run.sh "$out/socket-failure.exe" > "$out/socket-failure.out" 2> "$out/socket-failure.err" || status=$?
[[ $status == 0 ]] || fail "socket-failure.exe exited $status: $(head -5 "$out/socket-failure.out" "$out/socket-failure.err")"
expected=$'recvfrom dontwait -11\ntimeout set 0\ntimeout read 0: 1 s 500000 us\nread until the timeout -11, waited at least 1.4 s true\nnonblocking 0\nread -11\nrecvfrom -11\nsend 1\nread after send 1\nread at the end 0\nsend after shutdown negative true\nlinger 7 s set 0\nlinger read 0: on 1 for 7 s\nlinger set 0\nread after a reset -104\nlinger set 0\nreadResult after a reset error 104 0\nlinger set 0\nTLS read after a reset -1 0\ntimeouts set true\nreadResult from a silent peer error 11 0, waited at least 0.4 s true'
[[ "$(cat "$out/socket-failure.out")" == "$expected" ]] || fail "socket-failure.exe printed: $(cat "$out/socket-failure.out" "$out/socket-failure.err")"
# What a child inherits (inherit.ab): an inheritable pipe end of the parent is not in the child, which has the three streams only.
"$compiler" build tests/cases/windows/inherit.ab --target x86_64-windows-hosted -o "$out/inherit.exe" --fast --no-cache \
    > "$out/inherit.log" 2>&1 || { cat "$out/inherit.log" >&2; fail "inherit.ab did not build for Windows"; }
status=0
timeout 60 tools/windows/wine-run.sh "$out/inherit.exe" > "$out/inherit.out" 2> "$out/inherit.err" || status=$?
[[ $status == 42 ]] || fail "inherit.exe exited $status: $(head -5 "$out/inherit.out" "$out/inherit.err")"
[[ "$(cat "$out/inherit.out")" == 'child has the handle: false' ]] || fail "inherit.exe printed (a handle of the parent reached the child): $(cat "$out/inherit.out" "$out/inherit.err")"
echo "windows-syscalls:the translated numbers are $tested; an untranslated call is refused with status 70 and its number; a program reads its limits, CPUs and own path; abla_setjmp and abla_longjmp jump back from a deeper frame; a fault redirected with abla_windows_redirect jumps back too; a thread's interrupt word ends its wait with EINTR; another thread stops one spinning in executable memory with a CONTEXT redirect and one reading a pipe with CancelSynchronousIo; a child inherits its three streams and no other handle of the parent; a failed Winsock call is a negative errno and a receive timeout waits as long as Linux's; the vectored handler's entry takes $frame bytes of stack"
