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
  xtensaCohort = import ./nix/xtensa-cohort.nix { inherit pkgs llvmTools; };
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
    # tests/cases/rsa-keygen/check.sh: independent arithmetic on a generated key.
    bc
    # prlimit, for tools/run-limited.sh: an image may have none of its own.
    util-linux
    # tools/build-self-hosted-current.sh, for a compiler linked elsewhere.
    patchelf
    # What the test scripts call: rg, AArch64/x86-64 emulation (test-ct,
    # crypto-pure, bignum-secret), and a bash with its interactive builtins
    # (compgen) on hosts whose own bash lacks them, such as CI.
    ripgrep
    qemu-user
    bashInteractive
  ];

  shellHook = ''
    export ABLAC_DEV_SHELL=1
    # A host build's opt and llc (src/toolchain.ab), whatever else is first on PATH.
    export ABLA_LLVM_TOOLS="${llvmTools}/bin"
    ${pkgs.lib.optionalString xtensa ''
      # Target-local metadata, not another opt/llc directory on global PATH.
      export ABLA_XTENSA_LLVM_ROOT="''${ABLA_XTENSA_LLVM_ROOT:-${xtensaCohort}}"
    ''}
    export ABLA_MACOS_CLANG="${llvm.clang-unwrapped}/bin/clang"
    export ABLA_LINUX_OPENSSL_LIB="${pkgs.openssl.out}/lib"
    # What links here finds this OpenSSL when it runs. LD_LIBRARY_PATH would do it
    # too, but it also reaches the host's own tools, whose glibc is another.
    export NIX_LDFLAGS="-rpath ${pkgs.openssl.out}/lib ''${NIX_LDFLAGS:-}"
  '';
}
