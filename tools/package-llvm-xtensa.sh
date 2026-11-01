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
