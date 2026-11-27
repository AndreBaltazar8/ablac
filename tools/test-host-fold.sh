#!/usr/bin/env bash
# #811, compile speed: the host intrinsics (ablaHostIsMacOS, ablaHostIsIOS, ablaHostOwnsRuntime) are folded for the target
# before the analysis where the compiler's host agrees (bootstrapHostFoldParse, src/backend/llvm/backend.ab), so a Linux
# build no longer checks and lowers the runtime's macOS and libc paths. Seen through what the lowering demands
# (ABLA_COMPILER_DEMAND_TRACE): an x86-64 Linux hello on an x86-64 Linux host demands neither the macOS mapping copy
# (__ablaRuntimeHostHeapRemapCopy), nor libc's malloc, nor the Darwin system call; it still runs. The control: an
# aarch64-linux build from this host folds nothing (a cross build) and still demands the Darwin system call, so the probe
# does see such names. Other hosts: skipped.
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $compiler == /* || $compiler != */* ]] || compiler=$root/$compiler
if [[ $(uname -s) != Linux || $(uname -m) != x86_64 ]]; then
    echo 'host fold: not an x86-64 Linux host; skipped'
    exit 0
fi
out=$(mktemp -d "${TMPDIR:-/tmp}/abla-host-fold.XXXXXX")
trap 'rm -rf "$out"' EXIT
printf 'import "abla/io"\nfun main: int { println("hello"); 0 }\n' > "$out/hello.ab"
fail() {
    echo "host fold: $*" >&2
    exit 1
}
demanded() { # OUTPUT FLAGS...: the names the lowering of a --no-cache build demanded, one per line
    local output=$1
    shift
    ABLA_COMPILER_DEMAND_TRACE=1 "$compiler" build "$out/hello.ab" --no-cache "$@" -o "$output" 2> "$output.trace" > /dev/null ||
        { cat "$output.trace" >&2; fail "build $* failed"; }
    awk '$1 == "abla-demanded" { name = $4; sub(/^\./, "", name); sub(/^__abla_module_[0-9a-f]*__/, "", name); print name }' \
        "$output.trace" | sort -u
}
for mode in release fast; do
    flags=()
    [[ $mode == fast ]] && flags=(--fast)
    demanded "$out/linux-$mode" "${flags[@]}" > "$out/linux-$mode.names"
    [[ -s $out/linux-$mode.names ]] || fail "$mode: the demand trace is empty"
    for name in __ablaRuntimeHostHeapRemapCopy malloc ablaDarwinSyscall; do
        ! grep -xF "$name" "$out/linux-$mode.names" > /dev/null || fail "$mode x86-64 Linux build still demands $name"
    done
    [[ $("$out/linux-$mode") == hello ]] || fail "$mode x86-64 Linux hello does not print hello"
done
# The control: a cross build (aarch64-linux from this x86-64 host) folds nothing and keeps the macOS side, which LLVM
# folds instead, so the probe does see such names.
demanded "$out/aarch64" --target aarch64-linux > "$out/aarch64.names"
grep -xF ablaDarwinSyscall "$out/aarch64.names" > /dev/null ||
    fail 'the aarch64-linux cross control does not demand ablaDarwinSyscall: the probe sees nothing'
echo 'host fold: x86-64 Linux release and --fast demand no macOS or libc path; the aarch64-linux cross control keeps them'
