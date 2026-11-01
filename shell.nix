{ pkgs ? import ./nix/nixpkgs.nix
  # LLVM with the experimental Xtensa backend for ESP32 work (abla-embedded).
  # x86_64 Linux takes the prebuilt one (nix/llvm-prebuilt.nix); elsewhere it is
  # built from source, so CI (GitHub sets CI=true) leaves it off there. Override
  # with ABLA_NIX_XTENSA=1/0 or --arg xtensa true/false.
, xtensa ? (let forced = builtins.getEnv "ABLA_NIX_XTENSA"; in
    if forced != "" then forced == "1"
    else builtins.getEnv "CI" == "" || pkgs.stdenv.hostPlatform.system == "x86_64-linux")
  # Build LLVM from nix/llvm.nix and its patches: ABLA_NIX_LLVM_SOURCE=1 or
  # --arg llvmFromSource true. A change to those patches does this by itself
  # until a new release is pinned, and is an error on CI.
, llvmFromSource ? builtins.getEnv "ABLA_NIX_LLVM_SOURCE" == "1" }:

let
  toolchain = import ./nix/llvm.nix { inherit pkgs; };
  llvm = toolchain.llvmPackages;
  prebuilt = import ./nix/llvm-prebuilt.nix { inherit pkgs; };
  prebuiltUsable = pkgs.stdenv.hostPlatform.system == "x86_64-linux" && !llvmFromSource &&
    (prebuilt.matchesPatches || (if builtins.getEnv "CI" == "" then false else throw
      "nix/llvm-xtensa-*.patch differ from the pinned LLVM: release a new one (docs/llvm-xtensa.md)"));
  llvmTools = if !xtensa then llvm.llvm
    else if prebuiltUsable then prebuilt.llvm
    else toolchain.llvm;
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
    # prlimit, for tools/run-limited.sh: an image may have none of its own.
    util-linux
    # tools/build-self-hosted-current.sh, for a compiler linked elsewhere.
    patchelf
  ];

  shellHook = ''
    export ABLAC_DEV_SHELL=1
    export ABLA_MACOS_CLANG="${llvm.clang-unwrapped}/bin/clang"
    export ABLA_LINUX_OPENSSL_LIB="${pkgs.openssl.out}/lib"
    # What links here finds this OpenSSL when it runs. LD_LIBRARY_PATH would do it
    # too, but it also reaches the host's own tools, whose glibc is another.
    export NIX_LDFLAGS="-rpath ${pkgs.openssl.out}/lib ''${NIX_LDFLAGS:-}"
  '';
}
