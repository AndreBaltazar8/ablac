#!/usr/bin/env bash
# Install the checksum-pinned cohort into a release job's scratch directory.
set -euo pipefail
[[ $# == 1 ]] || { echo "usage: $0 <scratch-directory>" >&2; exit 2; }
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# shellcheck source=tools/llvm-linux-portable-pins.sh
source "$root/tools/llvm-linux-portable-pins.sh"
[[ $LLVM_LINUX_PORTABLE_SHA256 =~ ^[0-9a-f]{64}$ ]] ||
    { echo 'portable LLVM release archive is not pinned' >&2; exit 1; }
patch_sha=$(sha256sum "$root/nix/llvm-instcombine-fdiv-zero.patch" | cut -d' ' -f1)
[[ $patch_sha == "$LLVM_LINUX_PORTABLE_PATCH_SHA256" ]] ||
    { echo 'portable LLVM needs a new archive for the updated patch' >&2; exit 1; }

work=$(realpath -- "$1")
name=$LLVM_LINUX_PORTABLE_NAME
archive="$work/$name.tar.xz"
url="https://github.com/AndreBaltazar8/llvm-project/releases/download/$LLVM_LINUX_PORTABLE_TAG/$name.tar.xz"
curl -fsSL --retry 3 "$url" -o "$archive"
printf '%s  %s\n' "$LLVM_LINUX_PORTABLE_SHA256" "$archive" | sha256sum --check --strict >&2
tar -xJf "$archive" -C "$work"
prefix="$work/$name"
test "$(head -n 1 "$prefix/SOURCE")" = "$name"
grep -Fxq "$patch_sha  nix/llvm-instcombine-fdiv-zero.patch" "$prefix/SOURCE"
grep -Fxq 'glibc 2.35' "$prefix/SOURCE"
test -f "$prefix/lib/libLLVM.so.23.1"
test -f "$prefix/lib/libclang-cpp.so.23.1"
for tool in clang ld.lld llc lld llvm-ar llvm-as llvm-config llvm-dwarfdump llvm-extract llvm-readelf llvm-split opt wasm-ld; do
    test -x "$prefix/bin/$tool"
done
printf '%s\n' "$prefix"
