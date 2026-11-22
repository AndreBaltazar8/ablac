#!/usr/bin/env bash
# Build the fork against the portable Linux release's glibc floor.
set -euo pipefail
[[ $# == 2 && $1 =~ ^[1-9][0-9]*$ ]] || { echo "usage: $0 <revision> <output-dir>" >&2; exit 2; }
[[ $(uname -m) == x86_64 && $(getconf GNU_LIBC_VERSION) == 'glibc 2.35' ]] || {
    echo 'portable LLVM needs x86_64 Linux with glibc 2.35' >&2
    exit 2
}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output=$(realpath -m -- "$2")
commit=e4da75d481e81131665fbc2c368d3a956bbc4f2b # nix/llvm-fork.nix
name="llvm-23.1.3-fdiv-$1-portable-x86_64-linux"
work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT

git init "$work/source"
git -C "$work/source" fetch --depth=1 https://github.com/AndreBaltazar8/llvm-project.git "$commit"
git -C "$work/source" checkout --detach FETCH_HEAD
test "$(git -C "$work/source" rev-parse HEAD)" = "$commit"
patch -d "$work/source/llvm" -p1 -F 0 < "$root/nix/llvm-instcombine-fdiv-zero.patch"

prefix="$work/install"
# Linux clang links libclang-cpp when LLVM_LINK_LLVM_DYLIB is on. Both
# shared libraries must be in the distribution that moves with the tools.
components='LLVM;LTO;clang;clang-cpp;clang-resource-headers;lld;opt;llc;llvm-ar;llvm-as;llvm-config;llvm-dwarfdump;llvm-extract;llvm-readelf;llvm-readobj;llvm-split'
cmake -G Ninja -S "$work/source/llvm" -B "$work/build" \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=gcc-12 -DCMAKE_CXX_COMPILER=g++-12 \
    -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_INSTALL_LIBDIR=lib \
    -DLLVM_ENABLE_PROJECTS='clang;lld' -DLLVM_ENABLE_RUNTIMES=compiler-rt \
    -DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=ON \
    -DLLVM_ENABLE_ZLIB=FORCE_ON -DLLVM_ENABLE_ZSTD=FORCE_ON \
    -DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF -DLLVM_ENABLE_BINDINGS=OFF \
    -DLLVM_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_TESTS=OFF \
    -DLLVM_INCLUDE_BENCHMARKS=OFF -DLLVM_INCLUDE_EXAMPLES=OFF \
    -DLLVM_PARALLEL_COMPILE_JOBS=4 -DLLVM_PARALLEL_LINK_JOBS=1 \
    -DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON -DCOMPILER_RT_BUILD_BUILTINS=ON \
    -DCOMPILER_RT_BUILD_SANITIZERS=OFF -DCOMPILER_RT_BUILD_XRAY=OFF \
    -DCOMPILER_RT_BUILD_LIBFUZZER=OFF -DCOMPILER_RT_BUILD_PROFILE=OFF \
    -DCOMPILER_RT_BUILD_MEMPROF=OFF -DCOMPILER_RT_BUILD_ORC=OFF \
    -DLLVM_DISTRIBUTION_COMPONENTS="$components"
cmake --build "$work/build" --parallel 4 --target install-distribution-stripped
cmake --build "$work/build" --parallel 4 --target install-runtimes

# Check the install after moving it away from its CMake prefix.
bundle="$work/$name"
mv "$prefix" "$bundle"
test "$("$bundle/bin/llvm-config" --version)" = 23.1.3
test -f "$bundle/lib/libLLVM.so.23.1"
test -f "$bundle/lib/libclang-cpp.so.23.1"
"$bundle/bin/clang" --version
builtins=$("$bundle/bin/clang" --rtlib=compiler-rt -print-libgcc-file-name)
test -f "$builtins"
"$root/tools/test-external-llvm-fdiv.sh" "$bundle/bin"
"$bundle/bin/llc" -filetype=obj "$root/tests/cases/llvm-miscompiles/fdiv-zero-by-zero-times-value.ll" -o "$work/native.o"
"$bundle/bin/ld.lld" -r "$work/native.o" -o "$work/linked.o"

{
    printf '%s\n' "$name" "LLVM fork $commit" "ablac ${ABLA_SOURCE_SHA:-$(git -C "$root" rev-parse HEAD)}"
    (cd "$root" && sha256sum nix/llvm-instcombine-fdiv-zero.patch)
    getconf GNU_LIBC_VERSION
    gcc-12 -dumpfullversion
} > "$bundle/SOURCE"
cp "$work/source/llvm/LICENSE.TXT" "$bundle/LICENSE.TXT"
mkdir -p "$output"
tar -C "$work" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner -cf - "$name" |
    xz -9 -T2 > "$output/$name.tar.xz"
(cd "$output" && sha256sum "$name.tar.xz" | tee "$name.tar.xz.sha256")
