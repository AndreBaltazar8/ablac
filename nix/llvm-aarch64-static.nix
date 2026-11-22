# The same patched LLVM 23.1.3 and lld source as the x86 static toolchain,
# built on native AArch64 Linux. The lib and dev outputs hold the archives
# and headers for the static compiler. out holds opt and lld for verification.
{ pkgs ? import ./nixpkgs.nix }:
let
  llvm = import ./llvm-fork.nix { inherit pkgs; };
  lld = pkgs.llvmPackages_23.lld.override { libllvm = llvm; };
in
assert pkgs.stdenv.hostPlatform.system == "aarch64-linux";
{ inherit llvm lld; }
