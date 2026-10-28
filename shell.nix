{ pkgs ? import (builtins.fetchTarball {
    name = "nixpkgs-6510408d147d8c5e6d76043e899e9251756f6a75";
    url = "https://github.com/NixOS/nixpkgs/archive/6510408d147d8c5e6d76043e899e9251756f6a75.tar.gz";
    sha256 = "012w2z2w4k0c3kg9hcy9cpd7qgxgrpxvf0735vy014r7x9qhmbjw";
  }) {}
  # LLVM with the experimental Xtensa backend for ESP32 work (abla-embedded).
  # Off on CI (GitHub sets CI=true): host artifacts do not need it, and every
  # nested nix-shell would otherwise build LLVM from source. Override with
  # ABLA_NIX_XTENSA=1/0 or --arg xtensa true/false.
, xtensa ? (let forced = builtins.getEnv "ABLA_NIX_XTENSA"; in
    if forced != "" then forced == "1" else builtins.getEnv "CI" == "") }:

let
  toolchain = import ./nix/llvm.nix { inherit pkgs; };
  llvm = toolchain.llvmPackages;
  llvmTools = if xtensa then toolchain.llvm else llvm.llvm;
in
pkgs.mkShell {
  packages = with pkgs; [
    gcc
    gnumake
    time
    curl
    gdb
    valgrind
    # Listed before clang so its opt/llc win over anything clang brings.
    llvmTools
    llvm.clang-tools
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
    export LD_LIBRARY_PATH="${pkgs.openssl.out}/lib''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
  '';
}
