#!/usr/bin/env bash
# Native memory reached by ordinary code stays inside its bounds (#1139 area 10), tests/cases/native-memory:
#   - forged-stage: a ByteBuffer stage offset abla/bytes did not write (below 0, past the stage) writes nothing outside the stage;
#   - word-offset: NativeByteBuffer's eight-byte accessors refuse an offset near 2^63 (offset + 8 wrapped);
#   - reserve-huge: ByteBuffer.stageReserve of the largest int stops the program (its capacity + 1 wrapped to a 1-byte stage);
#   - json-tape: emit writes only what it sized, whatever the tape holds, and jsonStringify refuses a total past 2^62;
#   - websocket-bounds: the server's join and unmask helpers stay inside their strings;
#   - poll-count: ablaLinuxPollWaitCompact refuses a count outside 1..1024 (the overrun is silent natively: valgrind shows it);
#   - crypto-bounds: rsaPrivateOperation, keccakSha3's rate, a closed sponge and a short GCM nonce (the bytes after it are not read);
#   - regex-forged: a hand-built Regex whose spans stay -1 ends findAll and replace instead of searching from -1.
# Each program exits 0 printing "<name>: ok" (reserve-huge must stop before it prints "wrote"), in a release and a --fast build; on
# Linux also built for aarch64-linux and run under the AArch64 runner when there is one (tools/aarch64-test-runner.sh): there the
# top byte of an address is ignored, so the wrapped word offset wrote the 4 bytes before the buffer instead of faulting. With
# valgrind (the development shell has it), poll-count is also built --valgrind and must run with no error (its overrun is silent).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=$root/build/native-memory-bounds
rm -rf "$out"
mkdir -p "$out"
fail() { echo "native memory bounds: $1" >&2; exit 1; }
have_runner=0
if [[ $(uname -s) == Linux ]]; then
    source "$root/tools/aarch64-test-runner.sh"
    have_runner=1
    aarch64_runner_available || have_runner=0
fi
# check <name> <mode> <target>: builds and runs one program (mode release, fast or valgrind; target native or aarch64-linux).
check() {
    local name=$1 mode=$2 target=$3 binary="$out/$1-$2-$3" status=0
    local flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    [[ $mode == valgrind ]] && flags+=(--valgrind)
    [[ $target == native ]] || flags+=(--target "$target")
    "$compiler" build "tests/cases/native-memory/$name.ab" -o "$binary" "${flags[@]}" > "$binary.log" 2>&1 ||
        fail "$name ($mode, $target) did not build: $(head -4 "$binary.log")"
    if [[ $mode == valgrind ]]; then
        timeout 300 valgrind -q --error-exitcode=99 "$binary" < /dev/null > "$binary.out" 2>&1 || status=$?
    elif [[ $target == native ]]; then
        timeout 120 "$binary" < /dev/null > "$binary.out" 2>&1 || status=$?
    else
        aarch64_run --timeout 120 -- "$binary" < /dev/null > "$binary.out" 2>&1 || status=$?
    fi
    if [[ $name == reserve-huge ]]; then
        [[ $status != 0 ]] && ! grep "reserve-huge: wrote" "$binary.out" > /dev/null ||
            fail "$name ($mode, $target): the huge reservation was not stopped (exit $status): $(head -3 "$binary.out")"
    else
        [[ $status == 0 ]] && grep "^$name: ok$" "$binary.out" > /dev/null ||
            fail "$name ($mode, $target) exited $status: $(head -6 "$binary.out")"
    fi
}
targets=native
[[ $have_runner == 1 ]] && targets="native aarch64-linux"
for name in forged-stage word-offset reserve-huge json-tape websocket-bounds poll-count crypto-bounds regex-forged; do
    for mode in release fast; do
        for target in $targets; do
            # poll-count's sockets are Linux x86-64 epoll; under the AArch64 runner it is the same program, run as the others.
            check "$name" "$mode" "$target"
        done
    done
done
memcheck=no
if [[ $(uname -s)/$(uname -m) == Linux/x86_64 ]] && command -v valgrind > /dev/null; then
    check poll-count valgrind native
    memcheck=yes
fi
echo "native memory bounds: 8 programs stay inside their memory, release and --fast ($targets; valgrind: $memcheck)"
