# The AArch64 inputs of the statically linked compiler for aarch64-linux (#806 step C, tools/test-static-compiler-aarch64.sh), as plain files:
# llvm/ holds the cross-built libLLVM*.a (ABLA_STATIC_LLVM_LIB) and libs/ the target's libstdc++.a, libz.a and libgcc.a (ABLA_STATIC_TARGET_LIBS).
# Nothing in the binary cache has them: the cross libllvm builds from source (about two hours on four cores), which is why CI builds this once
# by hand (the aarch64-static-deps job) and keeps the result in the Actions cache, keyed by this file and the nixpkgs pin.
{ pkgs ? import ./nixpkgs.nix }:
let
  cross = pkgs.pkgsCross.aarch64-multiplatform;
  gcc = cross.stdenv.cc.cc;
in
pkgs.runCommand "abla-aarch64-static-deps" { } ''
  mkdir -p $out/llvm $out/libs
  cp -L ${cross.llvmPackages_23.libllvm.lib}/lib/libLLVM*.a $out/llvm/
  cp -L ${cross.zlib.static}/lib/libz.a $out/libs/
  cp -L ${gcc}/aarch64-unknown-linux-gnu/lib/libstdc++.a $out/libs/
  cp -L ${gcc.libgcc}/lib/libgcc.a $out/libs/
''
