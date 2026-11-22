#!/usr/bin/env bash
# Check and package native AArch64 LLVM and lld built by the workflow.
set -euo pipefail
[[ $# == 1 && ${REVISION:-} =~ ^[1-9][0-9]*$ && $REVISION != 1 ]] ||
    { echo "usage: REVISION=<2 or higher> $0 <nix-build-paths-file>" >&2; exit 2; }
test "$(uname -m)" = aarch64
mapfile -t paths < "$1"
test "${#paths[@]}" -eq 6
llvm_tools=${paths[0]}
llvm_lib=${paths[1]}
llvm_dev=${paths[2]}
lld_tools=${paths[3]}
lld_lib=${paths[4]}
lld_dev=${paths[5]}
name="llvm-23.1.3-fdiv-$REVISION-aarch64-linux"
bundle="pack/$name"
mkdir -p "$bundle/lib" "$bundle/include" check-bin
cp -L "$llvm_lib"/lib/libLLVM*.a "$lld_lib"/lib/liblld*.a "$bundle/lib/"
cp -RL "$llvm_dev/include/llvm" "$llvm_dev/include/llvm-c" \
    "$lld_dev/include/lld" "$bundle/include/"
for lib in LLVMOptDriver LLVMX86CodeGen LLVMAArch64CodeGen LLVMRISCVCodeGen LLVMWebAssemblyCodeGen LLVMXtensaCodeGen lldELF lldWasm lldCOFF lldCommon; do
    test -s "$bundle/lib/lib$lib.a"
done
"$llvm_tools/bin/llvm-nm" --defined-only "$bundle/lib/libLLVMOptDriver.a" > opt-driver.symbols
grep -Eq "[[:space:]]T[[:space:]]optMain$" opt-driver.symbols
c++ -std=c++17 -O2 -fno-exceptions -fno-rtti -I"$bundle/include" \
    -c runtime/abla_lld_shim.cpp -o shim.o
readelf -h "$bundle"/lib/*.a shim.o | awk '
  /Machine:/ { ++members; if ($NF != "AArch64") { print > "/dev/stderr"; bad=1 } }
  END { print members, "AArch64 ELF members checked"; exit (!members || bad) }
'
ln -s "$llvm_tools/bin/opt" "$llvm_tools/bin/llvm-as" "$lld_tools/bin/wasm-ld" check-bin/
tools/test-external-llvm-fdiv.sh check-bin --opt-and-lld
llvm_source=$(nix-build --no-out-link nix/llvm-aarch64-static.nix -A llvm.src)
cp "$llvm_source/llvm/LICENSE.TXT" "$bundle/LICENSE.TXT"
{
  printf "%s\n" "$name" "ablac $GITHUB_SHA"
  printf "LLVM fork %s\n" "$(nix-instantiate --eval --raw nix/llvm-aarch64-static.nix -A llvm.commit)"
  printf "%s\n" "nixpkgs 6510408d147d8c5e6d76043e899e9251756f6a75"
  sha256sum nix/llvm-instcombine-fdiv-zero.patch
} > "$bundle/SOURCE"
tar -C pack --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - "$name" | xz -9 -T2 > "$name.tar.xz"
sha256sum "$name.tar.xz" | tee "$name.tar.xz.sha256"
