# Cross-build the same patched fork as the native static LLVM cohorts.
{ pkgs ? import ./nixpkgs.nix }:
let
  target = pkgs.pkgsCross.riscv64;
  llvm = import ./llvm-fork.nix { pkgs = target; };
  lld = target.llvmPackages_23.lld.override { libllvm = llvm; };
  gcc = target.stdenv.cc;
in
{
  inherit llvm lld;
  inputs = pkgs.linkFarm "llvm-riscv64-static-sdk-inputs" {
    llvm-tools = llvm.out;
    llvm-lib = llvm.lib;
    llvm-dev = llvm.dev;
    lld-tools = lld.out;
    lld-lib = lld.lib;
    lld-dev = lld.dev;
    llvm-source = llvm.src;
    cc = gcc;
    gcc = gcc.cc;
    glibc = gcc.libc;
    glibc-dev = gcc.libc.dev;
    linux-headers = target.linuxHeaders;
    zlib-static = target.zlib.static;
    zlib-dev = target.zlib.dev;
  };
}
