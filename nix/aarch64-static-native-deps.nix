# The AArch64 inputs of the statically linked compiler for aarch64-linux (tools/test-static-compiler-aarch64.sh) from nixpkgs' NATIVE aarch64-linux
# packages, which cache.nixos.org has built (a download of a few hundred MB; an x86-64 nix only fetches the files, nothing of the target runs), instead of
# pkgsCross.aarch64-multiplatform's (the first version of this file), which is in no binary cache and builds from source in about two hours.
# llvm/ holds libLLVM*.a (ABLA_STATIC_LLVM_LIB) and libs/ the target's libstdc++.a, libz.a and libgcc.a (ABLA_STATIC_TARGET_LIBS).
{ pkgs ? import ./nixpkgs.nix }:
let
  native = import (pkgs.path) { system = "aarch64-linux"; };
  gcc = native.stdenv.cc.cc;
in
pkgs.runCommand "abla-aarch64-static-native-deps" { } ''
  mkdir -p $out/llvm $out/libs
  cp -L ${native.llvmPackages_23.libllvm.lib}/lib/libLLVM*.a $out/llvm/
  cp -L ${native.zlib.static}/lib/libz.a $out/libs/
  libstdcxx=$(find -L ${gcc} ${gcc.lib} -name libstdc++.a | head -n 1)
  libgcc=$(find -L ${gcc} ${gcc.libgcc} -name libgcc.a | head -n 1)
  test -n "$libstdcxx" && test -n "$libgcc"
  cp -L "$libstdcxx" $out/libs/
  cp -L "$libgcc" $out/libs/
''
