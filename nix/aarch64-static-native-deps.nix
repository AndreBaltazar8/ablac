# The AArch64 inputs of the statically linked compiler for aarch64-linux (tools/test-static-compiler-aarch64.sh).
# llvm/ holds libLLVM*.a (ABLA_STATIC_LLVM_LIB) and libs/ the target's libstdc++.a, libz.a and libgcc.a (ABLA_STATIC_TARGET_LIBS).
# With the lld in the process (#92, #1124) three more: lld/ the target's liblld*.a (ABLA_STATIC_LLD_LIB), include/ the LLVM and lld headers
# (ABLA_STATIC_LLD_INCLUDE and ABLA_STATIC_LLVM_INCLUDE: include/lld-only and include/llvm) and cxx-flags the C++ compiler flags that build
# runtime/abla_lld_shim.cpp for AArch64 from any host (the target's libstdc++ and C library headers; ABLA_STATIC_CXXFLAGS).
#
# The LLVM archives are the fork's, nixpkgs' LLVM 23.1.3 with nix/llvm-instcombine-fdiv-zero.patch (llvm-project #202482, decision #93), built on a
# native arm64 runner by .github/workflows/llvm-aarch64-static.yml (nix/llvm-aarch64-static.nix) and published as an asset of the fork's release
# llvm-23.1.3-xtensa-3; a static compiler on nixpkgs' stock archives would keep the stock LLVM's bugs. The target's libstdc++.a, libz.a and
# libgcc.a come from nixpkgs' NATIVE aarch64-linux packages, which cache.nixos.org has built (a download; an x86-64 nix only fetches the files,
# nothing of the target runs). So do liblld*.a and the headers: like on x86-64 (tools/static-llvm-env.sh) they are nixpkgs' own, the fix being in
# libLLVM*.a, which they link against, and the patches changing no header.
# `llvmArchives` (a fetchurl-like derivation holding llvm-*/lib/libLLVM*.a) may be given to take other LLVM archives.
{ pkgs ? import ./nixpkgs.nix, llvmArchives ? null }:
let
  native = import (pkgs.path) { system = "aarch64-linux"; };
  gcc = native.stdenv.cc.cc;
  llvm = native.llvmPackages_23;
  archives = if llvmArchives != null then llvmArchives else pkgs.fetchurl {
    url = "https://github.com/AndreBaltazar8/llvm-project/releases/download/llvm-23.1.3-xtensa-3/llvm-23.1.3-fdiv-1-aarch64-linux.tar.xz";
    sha256 = "4d2aede4d8ecc6fc2af6165970ebfa7498e218fbfa2cf01597a8d069800ed8f4";
  };
in
pkgs.runCommand "abla-aarch64-static-native-deps" { nativeBuildInputs = [ pkgs.xz pkgs.gnutar ]; } ''
  mkdir -p $out/llvm $out/libs $out/lld $out/include $TMPDIR/llvm
  tar -C $TMPDIR/llvm -xJf ${archives}
  cp $TMPDIR/llvm/llvm-23.1.3-fdiv-1-aarch64-linux/lib/libLLVM*.a $out/llvm/
  test -f $out/llvm/libLLVMSupport.a
  cp -L ${native.zlib.static}/lib/libz.a $out/libs/
  libstdcxx=$(find -L ${gcc} ${gcc.lib} -name libstdc++.a | head -n 1)
  libgcc=$(find -L ${gcc} ${gcc.libgcc} -name libgcc.a | head -n 1)
  test -n "$libstdcxx" && test -n "$libgcc"
  cp -L "$libstdcxx" $out/libs/
  cp -L "$libgcc" $out/libs/
  # lld in the process: the target's archives and the headers of lld and LLVM
  for archive in liblldELF.a liblldWasm.a liblldCOFF.a liblldCommon.a; do cp -L ${llvm.lld.lib}/lib/$archive $out/lld/; done
  cp -rL ${llvm.lld.dev}/include $out/include/lld-only
  cp -rL ${llvm.libllvm.dev}/include $out/include/llvm
  chmod -R u+w $out/include
  test -f $out/include/lld-only/lld/Common/Driver.h && test -f $out/include/llvm/llvm/Support/raw_ostream.h
  # the flags that build the shim for the target: its libstdc++ and C library headers (no host header may be found first)
  cxxroot=$(find -L ${gcc} -maxdepth 3 -type d -path '*include/c++/*' | head -n 1)
  echo "--target=aarch64-linux-gnu -nostdinc++ -isystem $cxxroot -isystem $cxxroot/aarch64-unknown-linux-gnu -isystem ${native.glibc.dev}/include" > $out/cxx-flags
''
