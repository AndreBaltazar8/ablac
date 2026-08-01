{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  packages = with pkgs; [
    gcc
    gnumake
    gdb
    valgrind
    clang-tools
    llvmPackages.llvm
    llvmPackages.clang
    llvmPackages.lld
  ];

  shellHook = ''
    export ABLAC_DEV_SHELL=1
  '';
}
