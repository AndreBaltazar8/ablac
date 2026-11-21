# The AArch64 inputs of the statically linked compiler for aarch64-linux (tools/test-static-compiler-aarch64.sh).
# llvm/ holds libLLVM*.a (ABLA_STATIC_LLVM_LIB) and libs/ the target's libstdc++.a, libz.a and libgcc.a (ABLA_STATIC_TARGET_LIBS).
#
# The LLVM archives are the fork's, nixpkgs' LLVM 23.1.3 with nix/llvm-instcombine-fdiv-zero.patch (llvm-project #202482, decision #93), built on a
# native arm64 runner by .github/workflows/llvm-aarch64-static.yml (nix/llvm-aarch64-static.nix) and published as an asset of the fork's release
# llvm-23.1.3-xtensa-3; a static compiler on nixpkgs' stock archives would keep the stock LLVM's bugs. The target's libstdc++.a, libz.a and
# libgcc.a come from nixpkgs' NATIVE aarch64-linux packages, which cache.nixos.org has built (a download; an x86-64 nix only fetches the files,
# nothing of the target runs).
{ pkgs ? import ./nixpkgs.nix }:
let
  native = import (pkgs.path) { system = "aarch64-linux"; };
  gcc = native.stdenv.cc.cc;
  llvmArchives = pkgs.fetchurl {
    url = "https://github.com/AndreBaltazar8/llvm-project/releases/download/llvm-23.1.3-xtensa-3/llvm-23.1.3-fdiv-1-aarch64-linux.tar.xz";
    sha256 = "4d2aede4d8ecc6fc2af6165970ebfa7498e218fbfa2cf01597a8d069800ed8f4";
  };
in
pkgs.runCommand "abla-aarch64-static-native-deps" { nativeBuildInputs = [ pkgs.xz pkgs.gnutar ]; } ''
  mkdir -p $out/llvm $out/libs $TMPDIR/llvm
  tar -C $TMPDIR/llvm -xJf ${llvmArchives}
  cp $TMPDIR/llvm/llvm-23.1.3-fdiv-1-aarch64-linux/lib/libLLVM*.a $out/llvm/
  test -f $out/llvm/libLLVMSupport.a
  cp -L ${native.zlib.static}/lib/libz.a $out/libs/
  libstdcxx=$(find -L ${gcc} ${gcc.lib} -name libstdc++.a | head -n 1)
  libgcc=$(find -L ${gcc} ${gcc.libgcc} -name libgcc.a | head -n 1)
  test -n "$libstdcxx" && test -n "$libgcc"
  cp -L "$libstdcxx" $out/libs/
  cp -L "$libgcc" $out/libs/
''
