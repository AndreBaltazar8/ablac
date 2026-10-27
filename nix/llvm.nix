# LLVM 23 for Abla: nixpkgs' llvmPackages_23 plus the experimental Xtensa
# backend (ESP32/ESP32-S3), so embedded builds need no second LLVM.
# Only libllvm is rebuilt; clang and lld stay the binary-cached ones.
{ pkgs }:

let
  llvmPackages = pkgs.llvmPackages_23;
  llvm = (llvmPackages.libllvm.override {
    devExtraCmakeFlags = [ "-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=Xtensa" ];
  }).overrideAttrs (_: {
    # The upstream test suite takes hours and does not cover the extra target.
    doCheck = false;
  });
in
{
  inherit llvmPackages llvm;
}
