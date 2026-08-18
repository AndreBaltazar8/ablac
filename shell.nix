{ pkgs ? import (builtins.fetchTarball {
    name = "nixpkgs-5e2a59a5b1a82f89f2c7e598302a9cacebb72a67";
    url = "https://github.com/NixOS/nixpkgs/archive/5e2a59a5b1a82f89f2c7e598302a9cacebb72a67.tar.gz";
    sha256 = "02rf59xj2v1ml7v35x4j64ax1fb7xx96ld7va6rifyxazmwsr4rb";
  }) {} }:

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
    binaryen
    nodejs
    openssl
  ];

  shellHook = ''
    export ABLAC_DEV_SHELL=1
    export ABLA_MACOS_CLANG="${pkgs.llvmPackages.clang-unwrapped}/bin/clang"
    export ABLA_LINUX_OPENSSL_LIB="${pkgs.openssl.out}/lib"
    export LD_LIBRARY_PATH="${pkgs.openssl.out}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  '';
}
