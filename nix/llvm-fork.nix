# The LLVM of nix/llvm.nix, built from the fork that carries its patches as
# commits: what tools/package-llvm-xtensa.sh packages for nix/llvm-prebuilt.nix.
# The fork's branch and nix/llvm-xtensa-*.patch have the same content.
{ pkgs }:

let
  base = (import ./llvm.nix { inherit pkgs; }).llvmPackages.libllvm;
  commit = "e4da75d481e81131665fbc2c368d3a956bbc4f2b";
  fork = pkgs.fetchzip {
    name = "llvm-project-${commit}";
    url = "https://github.com/AndreBaltazar8/llvm-project/archive/${commit}.tar.gz";
    sha256 = "19z9pypqvc89i9m61q3pvzclcjg30cymqvkkpscwwll57s5y40cp";
  };
in
(base.override {
  # nixpkgs takes its directories of the monorepo from here; its own patches
  # still apply.
  monorepoSrc = fork;
  devExtraCmakeFlags = [ "-DLLVM_EXPERIMENTAL_TARGETS_TO_BUILD=Xtensa" ];
}).overrideAttrs (old: {
  doCheck = false;
  passthru = (old.passthru or { }) // { inherit commit; };
})
