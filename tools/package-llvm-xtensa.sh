#!/usr/bin/env bash
# Builds the LLVM of nix/llvm-fork.nix (over an hour the first time) and packs
# what ablac uses of it for nix/llvm-prebuilt.nix. See docs/llvm-xtensa.md.
set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'usage: %s <release-tag> <output-directory>\n' "$0" >&2
    exit 2
fi
tag=$1
output=$(realpath -m "$2")
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

nix_expression="import $project_root/nix/llvm-fork.nix { pkgs = import $project_root/nix/nixpkgs.nix; }"
llvm=$(nix-build --no-out-link -E "($nix_expression).out")
lib=$(nix-build --no-out-link -E "($nix_expression).lib")
dev=$(nix-build --no-out-link -E "($nix_expression).dev")

working=$(mktemp -d)
trap 'chmod -R u+w "$working"; rm -rf -- "$working"' EXIT
name=$tag-x86_64-linux
bundle=$working/$name
mkdir -p "$bundle/out/bin" "$bundle/lib/lib" "$bundle/dev/bin"

# What src/toolchain.ab and tools/ call, and the usual readers of what they make.
for tool in FileCheck llc lli llvm-addr2line llvm-ar llvm-as llvm-bcanalyzer \
    llvm-cov llvm-cxxfilt llvm-dis llvm-dwarfdump llvm-extract llvm-ifs \
    llvm-link llvm-mc llvm-nm llvm-objcopy llvm-objdump llvm-profdata \
    llvm-ranlib llvm-readelf llvm-readobj llvm-size llvm-split llvm-strip \
    llvm-strings llvm-symbolizer opt; do
    cp -Pf "$llvm/bin/$tool" "$bundle/out/bin/"
    # A tool that links to another (llvm-ranlib, llvm-readelf) needs it too.
    if [[ -L $llvm/bin/$tool ]]; then
        cp -Pf "$(realpath "$llvm/bin/$tool")" "$bundle/out/bin/"
    fi
done
cp -P "$lib"/lib/libLLVM*.so* "$bundle/lib/lib/"
# The linkers, built against this LLVM: a Wasm release link is wasm-ld's LTO, which optimizes with the LLVM inside lld, so nixpkgs' lld
# would keep every bug this LLVM fixes (the InstCombine fdiv fix: tests/cases/fuzz-differential/fdiv-zero-by-zero-times-value.ab, wasm mode).
lld=$(nix-build --no-out-link -E "(import $project_root/nix/nixpkgs.nix).llvmPackages_23.lld.override { libllvm = ($nix_expression); }")
cp -L "$lld/bin/lld" "$bundle/out/bin/lld"
for linker in ld.lld wasm-ld ld64.lld lld-link; do ln -s lld "$bundle/out/bin/$linker"; done
# The same for clang: `clang -O2 -flto -c` is the pre-link step of a Wasm and of a non-whole-program ELF LTO build (src/toolchain.ab), and
# it optimizes with the LLVM inside clang. Only the two files that differ from nixpkgs' clang-unwrapped (the driver binary and
# libclang-cpp, both linked to this libLLVM) are shipped; nix/llvm-prebuilt.nix puts them into a copy of nixpkgs' clang (its headers,
# resource directory and wrapper support stay as they are).
clang_expression="(import $project_root/nix/nixpkgs.nix).llvmPackages_23.clang-unwrapped.override { libllvm = ($nix_expression); }"
clang=$(nix-build --no-out-link -E "$clang_expression")
clang_lib=$(nix-build --no-out-link -E "($clang_expression).lib")
mkdir -p "$bundle/clang/bin" "$bundle/clang/lib"
cp -L "$clang/bin/clang-23" "$bundle/clang/bin/clang-23"
cp -L "$clang_lib/lib/libclang-cpp.so.23.1" "$bundle/clang/lib/libclang-cpp.so.23.1"
cp -P "$dev/bin/llvm-config" "$bundle/dev/bin/"
cp "$(nix-build --no-out-link -E "($nix_expression).src")/llvm/LICENSE.TXT" "$bundle/LICENSE.TXT"
store_hash() { basename "$1" | cut -d- -f1; }
cat > "$bundle/store-hashes" <<HASHES
out $(store_hash "$llvm")
lib $(store_hash "$lib")
dev $(store_hash "$dev")
HASHES
printf '%s\n' "$tag" "$(nix-instantiate --eval --raw -E "($nix_expression).commit")" > "$bundle/SOURCE"
chmod -R u+w "$bundle"

mkdir -p "$output"
tar -C "$working" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -cf - "$name" | xz -9e -T0 > "$output/$name.tar.xz"
(cd "$output" && sha256sum "$name.tar.xz" > "$name.tar.xz.sha256")

# The static archives of the same build (#806 step C: the statically linked compiler links libLLVM*.a, tools/static-llvm-env.sh), as a
# second asset so a consumer of the dynamic LLVM does not download them. lib/ holds libLLVM*.a.
static_name=$tag-static-x86_64-linux
static_bundle=$working/$static_name
mkdir -p "$static_bundle/lib"
cp -L "$lib"/lib/libLLVM*.a "$static_bundle/lib/"
[[ -f $static_bundle/lib/libLLVMSupport.a ]] || { echo "package-llvm: no libLLVMSupport.a in $lib/lib" >&2; exit 1; }
cp "$bundle/LICENSE.TXT" "$bundle/SOURCE" "$static_bundle/"
chmod -R u+w "$static_bundle"
tar -C "$working" --sort=name --mtime=@0 --owner=0 --group=0 --numeric-owner \
    -cf - "$static_name" | xz -9e -T0 > "$output/$static_name.tar.xz"
(cd "$output" && sha256sum "$static_name.tar.xz" > "$static_name.tar.xz.sha256")
