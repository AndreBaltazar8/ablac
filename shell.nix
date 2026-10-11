{ pkgs ? import (builtins.fetchTarball {
    name = "nixpkgs-6510408d147d8c5e6d76043e899e9251756f6a75";
    url = "https://github.com/NixOS/nixpkgs/archive/6510408d147d8c5e6d76043e899e9251756f6a75.tar.gz";
    sha256 = "012w2z2w4k0c3kg9hcy9cpd7qgxgrpxvf0735vy014r7x9qhmbjw";
  }) {},
  # The pinned bootstrap release was linked in the previous pin's shell against
  # its LLVM 21 and reads that LLVM's opt output in process, so its first
  # rebuild runs with that LLVM's tools (tools/build-self-hosted-release.sh).
  bootstrapPkgs ? import (builtins.fetchTarball {
    name = "nixpkgs-5e2a59a5b1a82f89f2c7e598302a9cacebb72a67";
    url = "https://github.com/NixOS/nixpkgs/archive/5e2a59a5b1a82f89f2c7e598302a9cacebb72a67.tar.gz";
    sha256 = "02rf59xj2v1ml7v35x4j64ax1fb7xx96ld7va6rifyxazmwsr4rb";
  }) {} }:

let
  llvm = pkgs.llvmPackages_23;
in
pkgs.mkShell {
  packages = with pkgs; [
    gcc
    gnumake
    gdb
    valgrind
    llvm.clang-tools
    llvm.llvm
    llvm.clang
    llvm.lld
    binaryen
    nodejs
    openssl
  ];

  shellHook = ''
    export ABLAC_DEV_SHELL=1
    export ABLA_MACOS_CLANG="${llvm.clang-unwrapped}/bin/clang"
    export ABLA_LINUX_OPENSSL_LIB="${pkgs.openssl.out}/lib"
    export ABLA_BOOTSTRAP_LLVM="${bootstrapPkgs.llvmPackages_21.llvm}"
    export LD_LIBRARY_PATH="${pkgs.openssl.out}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  '';
}
