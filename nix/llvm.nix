# LLVM 23 for Abla: nixpkgs' llvmPackages_23 plus the experimental Xtensa
# backend (ESP32/ESP32-S3), so embedded builds need no second LLVM.
# Only libllvm is rebuilt; clang and lld stay the binary-cached ones.
{ pkgs }:

let
  llvmPackages = pkgs.llvmPackages_23;
  llvm = (llvmPackages.libllvm.override {
    devExtraCmakeFlags = [ "-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=Xtensa" ];
  }).overrideAttrs (old: {
    # The upstream test suite takes hours and does not cover the extra target.
    doCheck = false;
    # Xtensa code size, see each patch: CALL8 between flash-text functions
    # of one module (-xtensa-direct-calls; upstream always uses l32r +
    # callx8), EXTUI for masks and right shifts (never selected upstream), and
    # literal pools in their function's text section
    # (-xtensa-text-section-literals), which keeps an object's code together
    # under GNU ld so those CALL8s stay in range; MOVI and constant-pool L32R
    # rematerialize instead of being spilled to the stack; forward BEQZ/BNEZ
    # proven in range are emitted as BEQZ.N/BNEZ.N (-xtensa-narrow-branches).
    patches = (old.patches or [ ]) ++ [
      ./llvm-xtensa-direct-calls.patch
      ./llvm-xtensa-extui.patch
      ./llvm-xtensa-text-section-literals.patch
      ./llvm-xtensa-rematerialize.patch
      ./llvm-xtensa-narrow-branches.patch
    ];
  });
in
{
  inherit llvmPackages llvm;
}
