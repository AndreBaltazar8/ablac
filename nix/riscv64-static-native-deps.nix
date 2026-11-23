# Unpack the matching LLVM, lld and target sysroot from one verified RV64 SDK.
# For local validation pass --arg sdkArchive /absolute/path/to/the/archive.tar.xz.
{ pkgs ? import ./nixpkgs.nix, sdkArchive ? null }:
let
  archive = if sdkArchive != null then sdkArchive else pkgs.fetchurl {
    url = "https://github.com/AndreBaltazar8/llvm-project/releases/download/llvm-23.1.3-xtensa-3/llvm-23.1.3-fdiv-1-riscv64-linux.tar.xz";
    sha256 = "5962b6786305393b5ad28900cc4dd0ad8644bc908751f5d53d88f2906e7ff999";
  };
in
pkgs.runCommand "abla-riscv64-static-native-deps" {
  nativeBuildInputs = [ pkgs.gnutar pkgs.xz ];
} ''
  mkdir -p "$out"
  tar -xJf "${archive}" -C "$out" --strip-components=1

  cxx="$out/sysroot/include/c++/16.2.0"
  triple=riscv64-unknown-linux-gnu
  for member in \
    lib/libLLVMSupport.a lib/libLLVMOptDriver.a lib/libLLVMRISCVCodeGen.a \
    lib/liblldELF.a lib/liblldWasm.a lib/liblldCOFF.a lib/liblldCommon.a \
    include/llvm/Support/raw_ostream.h include/llvm-c/Core.h include/lld/Common/Driver.h \
    sysroot/lib/libstdc++.a sysroot/lib/libgcc.a sysroot/lib/libz.a \
    sysroot/include/stdio.h sysroot/include/linux/types.h sysroot/include/zlib.h \
    "sysroot/include/c++/16.2.0/vector" "sysroot/include/c++/16.2.0/$triple/bits/c++config.h"
  do
    if ! test -f "$out/$member"; then
      echo "RV64 SDK is missing $member" >&2
      exit 1
    fi
  done
  test -d "$cxx/backward"
  echo "--target=$triple -march=rv64gc -mabi=lp64d --sysroot=$out/sysroot -nostdinc++ -nostdlibinc -isystem $cxx -isystem $cxx/$triple -isystem $cxx/backward -isystem $out/sysroot/include" > "$out/cxx-flags"
''
