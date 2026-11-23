#!/usr/bin/env bash
# A thread's stack has a one-page guard, so a frame larger than a page could step over it and write into the memory below the stack (#1139
# area 7): here a function whose frame is a few KiB calls httpAsyncPlainRead, whose 64 KiB stack buffer a socket read fills from its low end,
# at depths of recursion that put that buffer across the guard; the memory below belongs to another thread. The compiler's stack probes (every page of
# a large frame is touched in order) make every such overflow hit the guard: the program must end with `panic: stack overflow` (exit 101)
# or finish, never die of a SIGSEGV elsewhere (exit 139) or with the other thread's data overwritten. The script finds the depth at which the
# recursion overflows and runs every depth from 40 below it to 2 above.
# Usage: tools/test-stack-guard.sh [compiler]; STACK_GUARD_TARGET=aarch64-linux STACK_GUARD_RUNNER=qemu-aarch64 runs the cross-built program under qemu-user.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
case "${STACK_GUARD_TARGET:+cross}$(uname -s)/$(uname -m)" in
    cross*) ;;
    Linux/x86_64 | Linux/aarch64) ;;
    *) echo "stack guard: skipped on this host"; exit 0 ;;
esac
out=build/stack-guard
rm -rf "$out"
mkdir -p "$out"
locals=400
{
    cat <<'HEAD'
import "abla/io"
import "abla/text"
import "abla/process"
import "abla/integer"
import "abla/net"
import "abla/http/async"
import "abla/sys/linux/process"

fun deep(n: int, table: array<int>, fd: int): int {
    if (n == 0) {
        var result = HttpAsyncRead("", 0)
        httpAsyncPlainRead(fd, result)
        return result.status
    }
HEAD
    for ((i = 0; i < locals; i++)); do echo "    val a$i = table[$((i % 8))] * $((i + 1)) + n"; done
    printf '    val r = deep(n - 1, table, fd)\n    n - (r'
    for ((i = 0; i < locals; i++)); do printf ' + a%d' "$i"; done
    printf ')\n}\n\n'
    cat <<'TAIL'
// A connection with 60000 bytes waiting, read on this thread when the recursion has reached the depth.
fun scenario(depth: int): int {
    val listener = tcpListenAddress(ipv4Loopback(0))
    var client = tcpConnectIpv4("127.0.0.1", listener.localPort(), 2000)
    val conn = listener.accept()
    client.write("A".repeat(60000))
    linuxSleepMillisecondsChecked(20)
    deep(depth, [3, 5, 7, 11, 13, 17, 19, 23], conn.descriptor)
}

// The thread whose memory lies just below the first one's stack: it keeps data on its own stack and allocates, so a store into its thread block
// or stack shows (the bytes written are 0x41, which a pointer made of them faults on).
fun hold(level: int, seed: int): int {
    val mine = seed * 31 + level
    if (level == 0) {
        linuxSleepMillisecondsChecked(150)
        var total = 0
        for (i in 0 until 2000) total = total + "x".repeat(10 + i % 7).size
        return total
    }
    val below = hold(level - 1, seed + 1)
    below + mine
}

fun main {
    val first = thread { scenario(processArgument(0).parseInt() ?? 0) }
    val second = thread { hold(30, 7) }
    linuxSleepMillisecondsChecked(30)
    val a = await first
    val b = await second
    println("finished ${a} ${b}")
}
TAIL
} > "$out/main.ab"
"$compiler" build "$out/main.ab" -o "$out/main" --no-cache ${STACK_GUARD_TARGET:+--target "$STACK_GUARD_TARGET"} > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
status_of() { # depth -> exit status of the program at that depth
    local status=0
    timeout 60 ${STACK_GUARD_RUNNER:-} "$out/main" "$1" > "$out/run.out" 2> "$out/run.err" || status=$?
    echo "$status"
}
# The first depth that overflows (exit 101): a doubling search, then bisection.
high=50
while [[ $(status_of $high) -eq 0 ]]; do
    high=$((high * 2))
    ((high < 100000)) || { echo "stack guard: no depth below 100000 overflows" >&2; exit 1; }
done
low=$((high / 2))
while ((high - low > 1)); do
    middle=$(((low + high) / 2))
    if [[ $(status_of $middle) -eq 0 ]]; then low=$middle; else high=$middle; fi
done
checked=0
for ((depth = high - 40; depth <= high + 2; depth++)); do
    ((depth > 0)) || continue
    status=$(status_of $depth)
    if [[ $status -ne 0 && $status -ne 101 ]]; then
        echo "stack guard: depth $depth (the first overflow is at $high) ended with status $status: $(head -c 300 "$out/run.err")" >&2
        exit 1
    fi
    if [[ $status -eq 101 ]] && ! grep -q 'panic: stack overflow' "$out/run.err"; then
        echo "stack guard: depth $depth exited 101 without the stack overflow message: $(head -c 300 "$out/run.err")" >&2
        exit 1
    fi
    checked=$((checked + 1))
done
echo "stack guard: $checked depths around the first overflow ($high) each finished or panicked with a stack overflow"
