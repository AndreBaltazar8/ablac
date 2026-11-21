# The AArch64 static archives with the InstCombine fdiv fix (llvm-project #202482, nix/llvm-instcombine-fdiv-zero.patch): nixpkgs'
# llvmPackages_23.libllvm of the host's own system with that one patch, no Xtensa target. Built on a NATIVE aarch64-linux machine
# (the llvm-aarch64-static workflow, once per LLVM revision; nothing caches it); lib/ holds libLLVM*.a and bin/opt the fixed optimizer.
{ pkgs ? import ./nixpkgs.nix }:
pkgs.llvmPackages_23.libllvm.overrideAttrs (old: {
  # The upstream test suite takes hours.
  doCheck = false;
  patches = (old.patches or [ ]) ++ [ ./llvm-instcombine-fdiv-zero.patch ];
})
