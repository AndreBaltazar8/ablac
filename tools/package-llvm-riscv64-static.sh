#!/usr/bin/env bash
# Verify the cross-built RV64 tools and their SDK, then create a release artifact.
set -euo pipefail
[[ $# == 1 && ${REVISION:-} =~ ^[1-9][0-9]*$ ]] ||
    { echo "usage: REVISION=<positive integer> $0 <sdk-inputs>" >&2; exit 2; }
inputs=$(realpath -- "$1")
triple=riscv64-unknown-linux-gnu
cxx="$inputs/cc/bin/$triple-g++"
gcc_version=$("$cxx" -dumpfullversion)
test "$("$cxx" -dumpmachine)" = "$triple"
target_flags=(-march=rv64gc -mabi=lp64d)

name="llvm-23.1.3-fdiv-$REVISION-riscv64-linux"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
bundle="$work/$name"
sysroot="$bundle/sysroot"
mkdir -p "$bundle/lib" "$bundle/include" "$sysroot/lib" "$sysroot/include/c++" "$work/bin"
cp -L "$inputs/llvm-lib"/lib/libLLVM*.a "$inputs/lld-lib"/lib/liblld*.a "$bundle/lib/"
cp -RL --no-preserve=mode "$inputs/llvm-dev/include/llvm" "$inputs/llvm-dev/include/llvm-c" \
    "$inputs/lld-dev/include/lld" "$bundle/include/"
for component in LLVMOptDriver LLVMX86CodeGen LLVMAArch64CodeGen LLVMRISCVCodeGen LLVMWebAssemblyCodeGen LLVMXtensaCodeGen lldELF lldWasm lldCOFF lldCommon; do
    test -s "$bundle/lib/lib$component.a"
done

for archive in libstdc++.a libgcc.a; do
    library=$("$cxx" "${target_flags[@]}" "-print-file-name=$archive")
    test -f "$library"
    cp -L "$library" "$sysroot/lib/"
    printf '%s %s\n' "$archive" "$(realpath "$library")" >> "$work/runtime-sources"
done
cp -L "$inputs/zlib-static/lib/libz.a" "$sysroot/lib/"
cp -RL --no-preserve=mode "$inputs/linux-headers/include/." "$sysroot/include/"
cp -RL --no-preserve=mode "$inputs/glibc-dev/include/." "$sysroot/include/"
cp -L "$inputs/zlib-dev"/include/{zlib.h,zconf.h} "$sysroot/include/"
cp -RL --no-preserve=mode "$inputs/gcc/include/c++/$gcc_version" "$sysroot/include/c++/"
cxx_include="$sysroot/include/c++/$gcc_version"
test -s "$cxx_include/$triple/bits/c++config.h"

"$cxx" "${target_flags[@]}" -std=c++17 -O2 -fno-exceptions -fno-rtti -nostdinc++ \
    -isystem "$cxx_include" -isystem "$cxx_include/$triple" -isystem "$cxx_include/backward" \
    -isystem "$sysroot/include" -I"$bundle/include" -c runtime/abla_lld_shim.cpp -o "$work/shim.o"
readelf -h "$bundle"/lib/*.a "$sysroot"/lib/*.a "$work/shim.o" | awk '
    /Class:/ { if ($NF != "ELF64") { print > "/dev/stderr"; bad=1 } }
    /Machine:/ { ++members; if ($NF != "RISC-V") { print > "/dev/stderr"; bad=1 } }
    /Flags:/ { ++abis; if ($0 !~ /double-float ABI/) { print > "/dev/stderr"; bad=1 } }
    END { print members, "RV64 LP64D ELF members checked"; exit (!members || abis != members || bad) }
'

qemu=$(command -v qemu-riscv64)
loader_root=$(realpath "$inputs/glibc")
for tool in opt llvm-as llvm-nm wasm-ld; do
    tool_root="$inputs/llvm-tools"
    [[ $tool != wasm-ld ]] || tool_root="$inputs/lld-tools"
    printf '#!/bin/bash\nexec %q -L %q %q "$@"\n' "$qemu" "$loader_root" "$tool_root/bin/$tool" > "$work/bin/$tool"
    chmod +x "$work/bin/$tool"
done
"$work/bin/llvm-nm" --defined-only "$bundle/lib/libLLVMOptDriver.a" > "$work/opt-driver.symbols"
grep -Eq '[[:space:]]T[[:space:]]optMain$' "$work/opt-driver.symbols"
tools/test-external-llvm-fdiv.sh "$work/bin" --opt-and-lld

cp "$inputs/llvm-source/llvm/LICENSE.TXT" "$bundle/LICENSE.TXT"
{
    printf '%s\n' "$name" "ablac $GITHUB_SHA"
    printf 'LLVM fork %s\n' "$(nix-instantiate --eval --raw nix/llvm-riscv64-static.nix -A llvm.commit)"
    printf '%s\n' 'nixpkgs 6510408d147d8c5e6d76043e899e9251756f6a75'
    printf '%s\n' "target $triple rv64gc/lp64d" "gcc/libstdc++ $gcc_version"
    for input in gcc glibc-dev linux-headers zlib-static zlib-dev; do
        printf '%s %s\n' "$input" "$(realpath "$inputs/$input")"
    done
    cat "$work/runtime-sources"
    sha256sum nix/llvm-instcombine-fdiv-zero.patch
} > "$bundle/SOURCE"
tar -C "$work" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - "$name" |
    xz -9 -T2 > "$name.tar.xz"
sha256sum "$name.tar.xz" | tee "$name.tar.xz.sha256"
