#!/usr/bin/env bash
# #811: `--target aarch64-linux` builds a static executable that needs no libc and no
# dynamic loader, and the small hosted programs and the system call checks behave under
# qemu-aarch64 exactly as the x86-64 builds do (output and exit status).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
if [[ $(uname -s) != Linux ]]; then echo 'aarch64 linux: Linux only'; exit 0; fi
out="$root/build/aarch64-linux"
rm -rf "$out"
mkdir -p "$out"
fail() { echo "aarch64 linux: $1" >&2; exit 1; }
have_qemu=1
command -v qemu-aarch64 > /dev/null || have_qemu=0
programs='tests/cases/libc-imports/hello.ab tests/cases/libc-imports/float-remainder.ab
tests/cases/libc-imports/strings-arrays.ab tests/cases/libc-imports/files.ab
tests/cases/libc-imports/tasks.ab tests/cases/libc-imports/threads.ab'
checks='tests/cases/linux-syscall/main.ab tests/cases/linux-syscall/legacy.ab tests/cases/linux-syscall/epoll.ab
tests/cases/modules/http-client.ab'
for source in $programs $checks; do
    name=$(basename "$source" .ab)-$(basename "$(dirname "$source")")
    for mode in release fast; do
        flags=''
        [[ $mode == release ]] || flags=--fast
        # shellcheck disable=SC2086
        "$compiler" build "$source" --target aarch64-linux -o "$out/$name-$mode" --no-cache $flags \
            > "$out/$name-$mode.log" 2>&1 || { cat "$out/$name-$mode.log" >&2; fail "$name $mode did not build"; }
        file_kind=$(readelf -h "$out/$name-$mode" | awk '/Machine:/ { print $2 }')
        [[ $file_kind == AArch64 ]] || fail "$name $mode is not an AArch64 executable ($file_kind)"
        if readelf -d "$out/$name-$mode" 2> /dev/null | grep -q NEEDED || readelf -l "$out/$name-$mode" | grep -q INTERP; then
            fail "$name $mode needs a shared library or a loader"
        fi
        [[ $have_qemu -eq 1 ]] || continue
        native_status=0 foreign_status=0
        # shellcheck disable=SC2086
        "$compiler" build "$source" -o "$out/$name-native-$mode" --no-cache $flags > /dev/null 2>&1 \
            || fail "$name $mode native build failed"
        (cd "$out" && timeout 120 "./$name-native-$mode" < /dev/null > "$name-$mode.native.out" 2> /dev/null) || native_status=$?
        (cd "$out" && timeout 300 qemu-aarch64 "./$name-$mode" < /dev/null > "$name-$mode.out" 2> /dev/null) || foreign_status=$?
        [[ $native_status -eq $foreign_status ]] || fail "$name $mode: status $foreign_status under qemu, $native_status natively"
        cmp -s "$out/$name-$mode.native.out" "$out/$name-$mode.out" || fail "$name $mode: output differs from the native build"
    done
done
if [[ $have_qemu -eq 1 ]]; then
    echo 'aarch64 linux: static libc-free builds run under qemu-aarch64 like the x86-64 ones'
else
    echo 'aarch64 linux: static libc-free builds made; no qemu-aarch64, not run'
fi
