#!/usr/bin/env bash
# An x86-64 Linux shared library as a host process loads it (#806). It names the dynamic loader (for __tls_get_addr, so
# that it resolves in a dlmopen namespace too) and no C library it does not use, and leaves only __tls_get_addr
# undefined; a library that starts a thread or calls a C function names libc and libpthread (as needed). A C host
# loads them (dlopen, and dlmopen into a new namespace, RTLD_NOW and RTLD_LAZY, RTLD_LOCAL), keeps its own malloc
# intact beside the library's heap, sees one heap and state per loaded file (a copy at another path is a library of its
# own), and an LD_PRELOADed allocator is never called by the library (its memory routines are hidden and its own).
# Concurrent calls into a library's state-mutating exports need the host's own lock (docs/compiler-api.md).
set -euo pipefail
compiler=${1:-build/ablac}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'x64 library: x86-64 Linux only'; exit 0; }
command -v clang >/dev/null || { echo 'x64 library: no clang for the host; skipped'; exit 0; }
out=build/x64-library
rm -rf "$out"
mkdir -p "$out"
cases=tests/cases/x64-library
needs() { # library pattern: whether its dynamic section names a library matching the pattern
    readelf -d "$1" | grep -Eq "NEEDED.*$2"
}
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    for name in lib threads extern; do
        "$compiler" build "$cases/$name.ab" --emit shared-library -o "$out/$name-$mode.so" "${flags[@]}"
    done
    if needs "$out/lib-$mode.so" 'lib(c|pthread)\.so'; then
        echo "x64 library ($mode): the library names a C library it does not use:" >&2
        readelf -d "$out/lib-$mode.so" | grep NEEDED >&2
        exit 1
    fi
    needs "$out/lib-$mode.so" 'ld-linux' || { echo "x64 library ($mode): the library does not name the loader" >&2; exit 1; }
    needs "$out/threads-$mode.so" 'lib(c|pthread)\.so' || { echo "x64 library ($mode): the thread library names no libc or libpthread" >&2; exit 1; }
    needs "$out/extern-$mode.so" 'libc\.so' || { echo "x64 library ($mode): the extern library names no libc" >&2; exit 1; }
    undefined=$(nm -D --undefined-only "$out/lib-$mode.so" | awk '{ s = $NF; sub(/@.*/, "", s); print s }' |
        grep -vx '__tls_get_addr\|_ITM_[a-zA-Z]*TMCloneTable\|__gmon_start__\|__cxa_finalize' || true)
    if [[ -n $undefined ]]; then
        printf 'x64 library (%s): undefined symbols the host would have to provide:\n%s\n' "$mode" "$undefined" >&2
        exit 1
    fi
    cp "$out/lib-$mode.so" "$out/copy-$mode.so"
done
clang "$cases/host.c" -o "$out/host" -ldl -lpthread
clang -shared -fPIC "$cases/preload.c" -o "$out/preload.so" -ldl
run_host() { # mode, then the environment as arguments to env
    local mode=$1
    shift
    env "$@" "$out/host" "$PWD/$out/lib-$mode.so" "$PWD/$out/copy-$mode.so" "$PWD/$out/threads-$mode.so" "$PWD/$out/extern-$mode.so" 2>&1
}
for mode in release fast; do
    result=$(run_host "$mode" A=1) || { echo "x64 library ($mode): the host run failed: $result" >&2; exit 1; }
    [[ $result == ok ]] || { echo "x64 library ($mode): the host run said: $result" >&2; exit 1; }
    result=$(run_host "$mode" "LD_PRELOAD=$PWD/$out/preload.so") ||
        { echo "x64 library ($mode): the host run under a preloaded allocator failed: $result" >&2; exit 1; }
    grep -q 'preload: library made no allocator calls' <<<"$result" ||
        { echo "x64 library ($mode): preload run: $result" >&2; exit 1; }
done
# A host built with AddressSanitizer, where the compiler has it (it does not support dlmopen, so the namespace phase is left out): its malloc is not the library's.
if clang -fsanitize=address "$cases/host.c" -o "$out/host-asan" -ldl -lpthread 2>/dev/null; then
    [[ $("$out/host-asan" "$PWD/$out/lib-release.so" "$PWD/$out/copy-release.so" 2>&1) == ok ]] ||
        { echo 'x64 library: the AddressSanitizer host run failed' >&2; exit 1; }
    echo 'x64 library: AddressSanitizer host ok'
else
    echo 'x64 library: no AddressSanitizer here; that host form skipped'
fi
echo 'x64 library: loads in every namespace and mode, one heap and state per loaded file, host allocator untouched'
