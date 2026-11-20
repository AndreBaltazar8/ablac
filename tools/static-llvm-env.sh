#!/usr/bin/env bash
# #806 step C: where the static compiler's archives come from. Prints the two `export` lines tools/build-static-compiler.sh needs
# (ABLA_STATIC_LLVM_LIB: a directory with libLLVM*.a; ABLA_STATIC_ZLIB: one with libz.a) from the pinned nixpkgs, whose LLVM lib output and
# zlib static output are binary-cached (about 590 MB of archives for X86, AArch64 and WebAssembly; the Xtensa fork is not in them, so a
# static compiler built from these has no Xtensa target). Use: eval "$(tools/static-llvm-env.sh)"
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
paths=$(nix-build --no-out-link -E "let pkgs = import $root/nix/nixpkgs.nix; in [pkgs.llvmPackages_23.libllvm.lib pkgs.zlib.static]")
llvm=$(sed -n 1p <<< "$paths")
zlib=$(sed -n 2p <<< "$paths")
[[ -f $llvm/lib/libLLVMSupport.a && -f $zlib/lib/libz.a ]] ||
    { echo "static-llvm-env: no libLLVMSupport.a in $llvm/lib or no libz.a in $zlib/lib" >&2; exit 1; }
printf 'export ABLA_STATIC_LLVM_LIB=%q\nexport ABLA_STATIC_ZLIB=%q\n' "$llvm/lib" "$zlib/lib"
