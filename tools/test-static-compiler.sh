#!/usr/bin/env bash
# #806 step C: the statically linked compiler (src/orc_main_static.ab on LLVM's static archives and Abla's own C library, no libc) is a static-pie executable
# with no needed library, and it builds programs byte for byte as the ordinary compiler does. Builds build/ablac-static, then builds each program of
# tests/cases/libc-imports with both and compares the executables. Single-threaded (the C library's pthread family is not threads yet).
# Needs the static archives, which the pinned shell's LLVM does not carry (ABLA_STATIC_LLVM_LIB, and ABLA_STATIC_ZLIB when the C compiler finds no libz.a);
# without them it says so and passes (CI gets them once the LLVM release publishes them).
# Usage: tools/test-static-compiler.sh [compiler]
set -euo pipefail
export LC_ALL=C
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux ]] || { echo 'static compiler: Linux only'; exit 0; }
if [[ -z ${ABLA_STATIC_LLVM_LIB:-} || ! -f ${ABLA_STATIC_LLVM_LIB}/libLLVMSupport.a ]]; then
    echo 'static compiler: skipped (no static LLVM: set ABLA_STATIC_LLVM_LIB to a directory with libLLVM*.a)'
    exit 0
fi
out=build/static-compiler
rm -rf "$out"
mkdir -p "$out"
tools/build-static-compiler.sh "$compiler" "$out/ablac-static" > "$out/build.log" 2>&1 ||
    { echo 'static compiler: the build failed' >&2; tail -8 "$out/build.log" >&2; exit 1; }
needed=$(readelf -d "$out/ablac-static" | grep -c '(NEEDED)' || true)
[[ $needed == 0 ]] || { echo "static compiler: $needed needed libraries" >&2; readelf -d "$out/ablac-static" >&2; exit 1; }
file -b "$out/ablac-static" | grep 'static-pie linked' >/dev/null || { echo 'static compiler: not a static-pie image' >&2; exit 1; }
export ABLA_NATIVE_JOBS=1 ABLA_CODEGEN_JOBS=1
count=0
for source in tests/cases/libc-imports/hello.ab tests/cases/libc-imports/strings-arrays.ab tests/cases/libc-imports/files.ab \
    tests/cases/libc-imports/float-remainder.ab tests/cases/libc-imports/tasks.ab tests/cases/libc-imports/threads.ab \
    tests/cases/libc-imports/jwt-verify.ab; do
    name=$(basename -- "$source" .ab)
    "$out/ablac-static" build "$source" -o "$out/$name.static" --no-cache > "$out/$name.static.log" 2>&1 ||
        { echo "static compiler: it failed to build $name" >&2; tail -5 "$out/$name.static.log" >&2; exit 1; }
    "$compiler" build "$source" -o "$out/$name.dynamic" --no-cache > "$out/$name.dynamic.log" 2>&1 ||
        { echo "static compiler: the ordinary compiler failed to build $name" >&2; exit 1; }
    cmp -s "$out/$name.static" "$out/$name.dynamic" || { echo "static compiler: $name differs from the ordinary compiler's" >&2; exit 1; }
    count=$((count + 1))
done
echo "static compiler: static-pie, no needed library, $count programs byte-identical to the ordinary compiler's"
