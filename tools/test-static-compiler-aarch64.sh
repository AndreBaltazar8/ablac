#!/usr/bin/env bash
# #806 step C, the second target: the statically linked compiler for AArch64 Linux (src/orc_main_static.ab cross-built with --target aarch64-linux on the
# AArch64 LLVM archives and the target's libstdc++.a/libz.a/libgcc.a) is a static-pie image with no needed library, and run under qemu-aarch64 it builds
# each program of tests/cases/libc-imports for aarch64-linux byte for byte as the ordinary (x86-64) compiler's cross build does. Needs
# ABLA_STATIC_LLVM_LIB (a directory with the AArch64 libLLVM*.a), ABLA_STATIC_TARGET_LIBS (a directory with libstdc++.a, libz.a and libgcc.a of AArch64) and
# qemu-aarch64; without them it says so and passes (docs/toolchain.md: pkgsCross.aarch64-multiplatform's llvmPackages_23.libllvm.lib, zlib.static, the cross gcc).
# Usage: tools/test-static-compiler-aarch64.sh [compiler]
set -euo pipefail
export LC_ALL=C
ulimit -c 0
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
unset ABLA_DEBUG ABLA_TEST_FAST_BUILDS
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || { echo 'static compiler aarch64: x86-64 Linux only'; exit 0; }
if [[ -z ${ABLA_STATIC_LLVM_LIB:-} || ! -f ${ABLA_STATIC_LLVM_LIB}/libLLVMSupport.a || -z ${ABLA_STATIC_TARGET_LIBS:-} ||
    ! -f ${ABLA_STATIC_TARGET_LIBS}/libstdc++.a ]] || ! command -v qemu-aarch64 > /dev/null; then
    echo 'static compiler aarch64: skipped (needs ABLA_STATIC_LLVM_LIB and ABLA_STATIC_TARGET_LIBS for AArch64, and qemu-aarch64)'
    exit 0
fi
export ABLA_STATIC_LLVM_LIB ABLA_STATIC_TARGET_LIBS
export ABLA_SYSROOT=${ABLA_SYSROOT:-$root}
out=build/static-compiler-aarch64
rm -rf "$out"
mkdir -p "$out"
"$compiler" build src/orc_main_static.ab --target aarch64-linux -o "$out/ablac-static" --no-cache > "$out/build.log" 2>&1 ||
    { echo 'static compiler aarch64: the build failed' >&2; grep -v 'warning' "$out/build.log" | tail -8 >&2; exit 1; }
file -b "$out/ablac-static" | grep 'ARM aarch64.*static-pie linked' > /dev/null || { echo 'static compiler aarch64: not an AArch64 static-pie image' >&2; exit 1; }
needed=$(readelf -d "$out/ablac-static" | grep -c '(NEEDED)' || true)
[[ $needed == 0 ]] || { echo "static compiler aarch64: $needed needed libraries" >&2; exit 1; }
export ABLA_NATIVE_JOBS=1 ABLA_CODEGEN_JOBS=1
count=0
for source in tests/cases/libc-imports/hello.ab tests/cases/libc-imports/strings-arrays.ab tests/cases/libc-imports/files.ab \
    tests/cases/libc-imports/float-remainder.ab tests/cases/libc-imports/tasks.ab tests/cases/libc-imports/threads.ab \
    tests/cases/libc-imports/jwt-verify.ab; do
    name=$(basename -- "$source" .ab)
    qemu-aarch64 "$out/ablac-static" build "$source" --target aarch64-linux -o "$out/$name.static" --no-cache > "$out/$name.static.log" 2>&1 ||
        { echo "static compiler aarch64: it failed to build $name" >&2; grep -v 'warning' "$out/$name.static.log" | tail -5 >&2; exit 1; }
    "$compiler" build "$source" --target aarch64-linux -o "$out/$name.cross" --no-cache > "$out/$name.cross.log" 2>&1 ||
        { echo "static compiler aarch64: the ordinary compiler failed to build $name" >&2; exit 1; }
    cmp -s "$out/$name.static" "$out/$name.cross" || { echo "static compiler aarch64: $name differs from the ordinary compiler's cross build" >&2; exit 1; }
    count=$((count + 1))
done
# The first milestone's program runs: hello world, built by the AArch64 compiler under qemu, prints under qemu.
[[ $(qemu-aarch64 "$out/hello.static") == hello ]] || { echo 'static compiler aarch64: the hello it built did not print hello' >&2; exit 1; }
echo "static compiler aarch64: static-pie, no needed library, $count programs byte-identical to the ordinary compiler's cross builds, hello runs"
