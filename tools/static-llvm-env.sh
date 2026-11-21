#!/usr/bin/env bash
# #806 step C: where the static compiler's archives come from. Prints the `export` lines tools/build-static-compiler.sh needs
# (ABLA_STATIC_LLVM_LIB: a directory with libLLVM*.a; ABLA_STATIC_ZLIB: one with libz.a; for lld in the process, #92: ABLA_STATIC_LLD_LIB with
# liblld*.a, ABLA_STATIC_LLD_INCLUDE and ABLA_STATIC_LLVM_INCLUDE with the headers of lld and LLVM). The LLVM archives are the ones of the fork build
# the default compiler's LLVM comes from (nix/llvm-prebuilt.nix, staticLibs: nixpkgs' LLVM 23.1.3 with our patches, among them the InstCombine
# fdiv fix, #93), about 590 MB, X86, AArch64, WebAssembly and Xtensa; a static compiler built from the stock nixpkgs archives would keep the stock
# LLVM's bugs. liblld*.a, the headers and zlib's static output are nixpkgs' (binary-cached): the fix is in libLLVM*.a, which the lld archives link
# against, and the patches change no header. Use: eval "$(tools/static-llvm-env.sh)"
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
paths=$(nix-build --no-out-link -E "let pkgs = import $root/nix/nixpkgs.nix; in [(import $root/nix/llvm-prebuilt.nix { inherit pkgs; }).staticLibs pkgs.zlib.static pkgs.llvmPackages_23.lld.lib pkgs.llvmPackages_23.lld.dev pkgs.llvmPackages_23.libllvm.dev]")
llvm=$(sed -n 1p <<< "$paths")
zlib=$(sed -n 2p <<< "$paths")
lld=$(sed -n 3p <<< "$paths")
lld_dev=$(sed -n 4p <<< "$paths")
llvm_dev=$(sed -n 5p <<< "$paths")
[[ -f $llvm/lib/libLLVMSupport.a && -f $zlib/lib/libz.a ]] ||
    { echo "static-llvm-env: no libLLVMSupport.a in $llvm/lib or no libz.a in $zlib/lib" >&2; exit 1; }
[[ -f $lld/lib/liblldELF.a && -f $lld_dev/include/lld/Common/Driver.h && -f $llvm_dev/include/llvm/Support/raw_ostream.h ]] ||
    { echo "static-llvm-env: no liblldELF.a in $lld/lib, or no lld or LLVM headers" >&2; exit 1; }
printf 'export ABLA_STATIC_LLVM_LIB=%q\nexport ABLA_STATIC_ZLIB=%q\n' "$llvm/lib" "$zlib/lib"
printf 'export ABLA_STATIC_LLD_LIB=%q\nexport ABLA_STATIC_LLD_INCLUDE=%q\nexport ABLA_STATIC_LLVM_INCLUDE=%q\n' "$lld/lib" "$lld_dev/include" "$llvm_dev/include"
