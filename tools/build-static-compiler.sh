#!/usr/bin/env bash
# #806 step C: the statically linked compiler, build/ablac-static (src/orc_main_static.ab on LLVM's static archives and Abla's own C library, no libc). Needs
# ABLA_STATIC_LLVM_LIB (a directory with libLLVM*.a; ABLA_STATIC_ZLIB one with libz.a when the C compiler finds none). It runs single-threaded for now:
# the pthread family of src/static_libc is not threads yet, so the script's check builds with ABLA_NATIVE_JOBS=1 ABLA_CODEGEN_JOBS=1.
# ABLA_STATIC_TARGET=aarch64-linux or riscv64-linux selects a Linux target.
# Use LLVM, lld, libstdc++, zlib and libgcc archives for that target.
# ABLA_STATIC_LLD_LIB, ABLA_STATIC_LLD_INCLUDE, ABLA_STATIC_LLVM_INCLUDE: lld in the process, below; for AArch64 too (#1124): nix/aarch64-static-native-deps.nix makes them (lld/, include/lld-only,
# include/llvm) and ABLA_STATIC_CXXFLAGS (its cxx-flags file: the target's headers), ABLA_STATIC_CXX the C++ compiler (c++; clang++ cross-builds the shim from x86-64).
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
    [[ $ABLA_STATIC_TARGET == aarch64-linux || $ABLA_STATIC_TARGET == riscv64-linux ]] ||
        { echo "static compiler: unsupported ABLA_STATIC_TARGET $ABLA_STATIC_TARGET" >&2; exit 2; }
    for library in libstdc++.a libz.a libgcc.a; do
        [[ -n ${ABLA_STATIC_TARGET_LIBS:-} && -f $ABLA_STATIC_TARGET_LIBS/$library ]] ||
            { echo "static compiler: ABLA_STATIC_TARGET_LIBS is missing the target's $library" >&2; exit 2; }
    done
    export ABLA_STATIC_TARGET_LIBS
    target_arguments=(--target "$ABLA_STATIC_TARGET")
fi
if [[ ${ABLA_STATIC_TARGET:-} == riscv64-linux && -z ${ABLA_STATIC_LLD_LIB:-} ]]; then
    echo 'static compiler: riscv64-linux requires ABLA_STATIC_LLD_LIB and the matching headers for the real shim' >&2
    exit 2
fi
# In-process lld (#92, runtime/abla_lld_shim.cpp, the one C++ source): with ABLA_STATIC_LLD_LIB (a directory with liblldELF.a, liblldWasm.a, liblldCOFF.a, liblldCommon.a),
# ABLA_STATIC_LLD_INCLUDE (lld's headers) and ABLA_STATIC_LLVM_INCLUDE (LLVM's) the compiler carries lld and runs its links in its own process (x86-64 only for now);
# without them it carries a stub and runs the external ld.lld/wasm-ld as before. tools/static-llvm-env.sh prints all of them.
shim_object=
if [[ -n ${ABLA_STATIC_LLD_LIB:-} ]]; then
    [[ -f ${ABLA_STATIC_LLD_LIB}/liblldELF.a && -f ${ABLA_STATIC_LLD_LIB}/liblldWasm.a && -f ${ABLA_STATIC_LLD_LIB}/liblldCOFF.a && -f ${ABLA_STATIC_LLD_LIB}/liblldCommon.a &&
        -f ${ABLA_STATIC_LLD_INCLUDE:-/none}/lld/Common/Driver.h && -f ${ABLA_STATIC_LLVM_INCLUDE:-/none}/llvm/Support/raw_ostream.h ]] ||
        { echo 'static compiler: ABLA_STATIC_LLD_LIB needs liblldELF.a, liblldWasm.a, liblldCOFF.a, liblldCommon.a, and ABLA_STATIC_LLD_INCLUDE and ABLA_STATIC_LLVM_INCLUDE the lld and LLVM headers' >&2; exit 2; }
    shim_object=$(dirname -- "$output")/abla_lld_shim.o
    # shellcheck disable=SC2086
    ${ABLA_STATIC_CXX:-c++} ${ABLA_STATIC_CXXFLAGS:-} -std=c++17 -O2 -fno-exceptions -fno-rtti -c "$root/runtime/abla_lld_shim.cpp" -I"$ABLA_STATIC_LLD_INCLUDE" -I"$ABLA_STATIC_LLVM_INCLUDE" -o "$shim_object"
    export ABLA_STATIC_LLD_OBJECT=$shim_object ABLA_STATIC_LLD_LIB
fi
"$compiler" build src/orc_main_static.ab -o "$output" --no-cache "${target_arguments[@]}"
[[ -x $output ]] || { echo "static compiler: no $output" >&2; exit 1; }
echo "built $output: $(file -b "$output" | cut -c1-100)"
