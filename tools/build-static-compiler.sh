#!/usr/bin/env bash
# #806 step C: the statically linked compiler, build/ablac-static (src/orc_main_static.ab on LLVM's static archives and Abla's own C library, no libc). Needs
# ABLA_STATIC_LLVM_LIB (a directory with libLLVM*.a; ABLA_STATIC_ZLIB one with libz.a when the C compiler finds none). It runs single-threaded for now:
# the pthread family of src/static_libc is not threads yet, so the script's check builds with ABLA_NATIVE_JOBS=1 ABLA_CODEGEN_JOBS=1.
# ABLA_STATIC_TARGET=aarch64-linux cross-builds it for AArch64 Linux instead (the AArch64 archives in ABLA_STATIC_LLVM_LIB and the target's libstdc++.a, libz.a,
# libgcc.a in ABLA_STATIC_TARGET_LIBS; nix/aarch64-static-deps.nix makes both); run it under qemu-aarch64 or on an AArch64 machine.
# Usage: tools/build-static-compiler.sh [compiler] [output]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
output=${2:-build/ablac-static}
[[ -n ${ABLA_STATIC_LLVM_LIB:-} && -f ${ABLA_STATIC_LLVM_LIB}/libLLVMSupport.a ]] ||
    { echo 'static compiler: set ABLA_STATIC_LLVM_LIB to a directory with libLLVM*.a' >&2; exit 2; }
export ABLA_STATIC_LLVM_LIB
# The launcher's default cap is 2048 MB; the frontend on the compiler's own source needs about 1.8 GB resident and the static link more (CI's first run died with "out of memory").
export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-8192}
target_arguments=()
if [[ -n ${ABLA_STATIC_TARGET:-} ]]; then
    [[ $ABLA_STATIC_TARGET == aarch64-linux ]] || { echo "static compiler: ABLA_STATIC_TARGET must be aarch64-linux, got $ABLA_STATIC_TARGET" >&2; exit 2; }
    [[ -n ${ABLA_STATIC_TARGET_LIBS:-} && -f ${ABLA_STATIC_TARGET_LIBS}/libstdc++.a ]] ||
        { echo 'static compiler: set ABLA_STATIC_TARGET_LIBS to a directory with the AArch64 libstdc++.a, libz.a and libgcc.a' >&2; exit 2; }
    export ABLA_STATIC_TARGET_LIBS
    target_arguments=(--target "$ABLA_STATIC_TARGET")
fi
"$compiler" build src/orc_main_static.ab -o "$output" --no-cache "${target_arguments[@]}"
[[ -x $output ]] || { echo "static compiler: no $output" >&2; exit 1; }
echo "built $output: $(file -b "$output" | cut -c1-100)"
