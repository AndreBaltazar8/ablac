#!/usr/bin/env bash
# Native memory reached by ordinary code stays inside its bounds (#1139 area 10): a ByteBuffer whose stage offset was not written
# by abla/bytes writes nothing outside its stage (tests/cases/native-memory/forged-stage.ab), and NativeByteBuffer's eight-byte
# accessors refuse an offset near 2^63 (word-offset.ab). Each program exits 0 and prints "<name>: ok", in a release and a --fast
# build, and on Linux also built for aarch64-linux and run under the AArch64 runner when there is one (tools/aarch64-test-runner.sh):
# there the top byte of an address is ignored, so the wrapped word offset wrote the 4 bytes before the buffer instead of faulting.
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
# check <name> <mode> <target>: builds and runs one program; it must exit 0 and print "<name>: ok".
check() {
    local name=$1 mode=$2 target=$3 binary="$out/$1-$2-$3" status=0
    local flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    [[ $target == native ]] || flags+=(--target "$target")
    "$compiler" build "tests/cases/native-memory/$name.ab" -o "$binary" "${flags[@]}" > "$binary.log" 2>&1 ||
        fail "$name ($mode, $target) did not build: $(head -4 "$binary.log")"
    if [[ $target == native ]]; then
        "$binary" > "$binary.out" 2>&1 || status=$?
    else
        aarch64_run --timeout 120 -- "$binary" < /dev/null > "$binary.out" 2>&1 || status=$?
    fi
    [[ $status == 0 ]] && grep "^$name: ok$" "$binary.out" > /dev/null ||
        fail "$name ($mode, $target) exited $status: $(head -4 "$binary.out")"
}
targets=native
[[ $have_runner == 1 ]] && targets="native aarch64-linux"
for name in forged-stage word-offset; do
    for mode in release fast; do
        for target in $targets; do check "$name" "$mode" "$target"; done
    done
done
echo "native memory bounds: a forged ByteBuffer stage offset writes nothing outside the stage, and the eight-byte NativeByteBuffer accessors refuse an offset near 2^63, in release and --fast builds ($targets)"
