# The AArch64 inputs of the statically linked compiler for aarch64-linux (tools/test-static-compiler-aarch64.sh).
# llvm/ holds libLLVM*.a (ABLA_STATIC_LLVM_LIB) and libs/ the target's libstdc++.a, libz.a and libgcc.a (ABLA_STATIC_TARGET_LIBS).
# With the lld in the process (#92, #1124) three more: lld/ the target's liblld*.a (ABLA_STATIC_LLD_LIB), include/ the LLVM and lld headers
# (ABLA_STATIC_LLD_INCLUDE and ABLA_STATIC_LLVM_INCLUDE: include/lld-only and include/llvm) and cxx-flags the C++ compiler flags that build
# runtime/abla_lld_shim.cpp for AArch64 from any host (the target's libstdc++ and C library headers; ABLA_STATIC_CXXFLAGS).
#
# The LLVM and lld archives and their headers come from the same fork build,
# with the InstCombine fdiv fix, produced by .github/workflows/llvm-aarch64-static.yml.
# The target's libstdc++.a, libz.a and libgcc.a remain native nixpkgs downloads.
# `llvmArchives` can override the complete cohort for local validation.
{ pkgs ? import ./nixpkgs.nix, llvmArchives ? null }:
let
  native = import (pkgs.path) { system = "aarch64-linux"; };
  gcc = native.stdenv.cc.cc;
  archives = if llvmArchives != null then llvmArchives else pkgs.fetchurl {
    url = "https://github.com/AndreBaltazar8/llvm-project/releases/download/llvm-23.1.3-xtensa-3/llvm-23.1.3-fdiv-2-aarch64-linux.tar.xz";
    sha256 = "5fd33191ff4026179481f8183b9c03947fc600acdc7a0afe696883dfd8887ff9";
  };
in
pkgs.runCommand "abla-aarch64-static-native-deps" { nativeBuildInputs = [ pkgs.xz pkgs.gnutar ]; } ''
  mkdir -p "$out/llvm" "$out/libs" "$out/lld" "$out/include/llvm" "$out/include/lld-only" "$TMPDIR/llvm"
  tar -C "$TMPDIR/llvm" -xJf ${archives}
  set -- "$TMPDIR/llvm"/llvm-*-aarch64-linux
  test "$#" -eq 1 && test -d "$1"
  cohort=$1
  cp "$cohort"/lib/libLLVM*.a "$out/llvm/"
  cp "$cohort"/lib/liblld*.a "$out/lld/"
  cp -R "$cohort/include/llvm" "$cohort/include/llvm-c" "$out/include/llvm/"
  cp -R "$cohort/include/lld" "$out/include/lld-only/"
  cp "$cohort/SOURCE" "$out/SOURCE"
  test -f "$out/llvm/libLLVMSupport.a" && test -f "$out/llvm/libLLVMOptDriver.a"
  for archive in liblldELF.a liblldWasm.a liblldCOFF.a liblldCommon.a; do test -f "$out/lld/$archive"; done
  cp -L ${native.zlib.static}/lib/libz.a $out/libs/
  libstdcxx=$(find -L ${gcc} ${gcc.lib} -name libstdc++.a | head -n 1)
  libgcc=$(find -L ${gcc} ${gcc.libgcc} -name libgcc.a | head -n 1)
  test -n "$libstdcxx" && test -n "$libgcc"
  cp -L "$libstdcxx" $out/libs/
  cp -L "$libgcc" $out/libs/
  test -f $out/include/lld-only/lld/Common/Driver.h && test -f $out/include/llvm/llvm/Support/raw_ostream.h
  # the flags that build the shim for the target: its libstdc++ and C library headers (no host header may be found first)
  cxxroot=$(find -L ${gcc} -maxdepth 3 -type d -path '*include/c++/*' | head -n 1)
  echo "--target=aarch64-linux-gnu -nostdinc++ -isystem $cxxroot -isystem $cxxroot/aarch64-unknown-linux-gnu -isystem ${native.glibc.dev}/include" > $out/cxx-flags
''
