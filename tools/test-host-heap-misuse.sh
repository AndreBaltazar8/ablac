#!/usr/bin/env bash
# The runtime's own heap (x86-64 and AArch64 Linux, macOS; the static libc's malloc and free) stops the program on a free it
# cannot honour (#1139 area 10): a second free of a small block (its class's list would hand it out twice), a second free of a
# mapping of its own (kept for reuse twice), and a free of an address inside a block. Each must die by the heap's trap
# (SIGILL); the control, 100k mixed allocations and frees, must pass with __ablaRuntimeHostHeapVerify clean. Release and --fast
# builds (the --fast one links the compiler's prebuilt host runtime).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
out="$root/build/host-heap-misuse"
rm -rf "$out"
mkdir -p "$out"
fail() { echo "host heap misuse: $1" >&2; exit 1; }
case "$(uname -s)-$(uname -m)" in
    Linux-x86_64|Linux-aarch64|Darwin-*) ;;
    *) echo "host heap misuse: this host keeps libc's allocator; skipped"; exit 0 ;;
esac
for kind in release fast; do
    flags=()
    [[ $kind == fast ]] && flags=(--fast)
    "$compiler" build "$root/tests/host-heap-misuse/main.ab" -o "$out/heap-$kind" "${flags[@]}" > "$out/build-$kind.log" 2>&1 ||
        fail "$kind: the program did not build: $(head -c 600 "$out/build-$kind.log")"
    status=0
    timeout 60 "$out/heap-$kind" control > /dev/null 2>&1 || status=$?
    [[ $status == 0 ]] || fail "$kind control: status $status (50 + n: __ablaRuntimeHostHeapVerify found problem n)"
    for mode in double large interior; do
        status=0
        timeout 60 "$out/heap-$kind" "$mode" > /dev/null 2>&1 || status=$?
        [[ $status == 132 ]] || fail "$kind $mode: status $status, not the heap's trap (132): 30/35 mean the block was handed out twice, 41 the free was accepted"
    done
done
echo "host heap misuse: double frees and interior frees stop the program; the control passes"
