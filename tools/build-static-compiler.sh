#!/usr/bin/env bash
# #806 step C: the statically linked compiler, build/ablac-static (src/orc_main_static.ab on LLVM's static archives and Abla's own C library, no libc). Needs
# ABLA_STATIC_LLVM_LIB (a directory with libLLVM*.a; ABLA_STATIC_ZLIB one with libz.a when the C compiler finds none). It runs single-threaded for now:
# the pthread family of src/static_libc is not threads yet, so the script's check builds with ABLA_NATIVE_JOBS=1 ABLA_CODEGEN_JOBS=1.
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
"$compiler" build src/orc_main_static.ab -o "$output" --no-cache
[[ -x $output ]] || { echo "static compiler: no $output" >&2; exit 1; }
echo "built $output: $(file -b "$output" | cut -c1-100)"
