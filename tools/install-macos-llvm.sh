#!/usr/bin/env bash
# Install the published, checksum-pinned native LLVM cohort for CI/release.
# Never rebuild LLVM here or substitute a Homebrew LLVM for a missing pin.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
[[ $(uname -s) == Darwin ]] || { echo 'install-macos-llvm: macOS only' >&2; exit 2; }
# shellcheck source=tools/llvm-macos-pins.sh
source "$root/tools/llvm-macos-pins.sh"
architecture=$(uname -m)
case "$architecture" in
    arm64) expected=$LLVM_MACOS_ARM64_SHA256 ;;
    x86_64) expected=$LLVM_MACOS_X86_64_SHA256 ;;
    *) echo "install-macos-llvm: unsupported architecture $architecture" >&2; exit 2 ;;
esac
[[ $expected =~ ^[0-9a-f]{64}$ ]] || {
    echo "install-macos-llvm: $architecture archive has not been published and pinned" >&2
    exit 1
}
patch_sha256=$(shasum -a 256 "$root/nix/llvm-instcombine-fdiv-zero.patch" | cut -d' ' -f1)
[[ $patch_sha256 == "$LLVM_MACOS_PATCH_SHA256" ]] || {
    echo 'install-macos-llvm: LLVM patch changed; build and pin new archives' >&2; exit 1;
}
: "${GITHUB_ENV:?this CI installer requires GITHUB_ENV}"
: "${GITHUB_PATH:?this CI installer requires GITHUB_PATH}"
name="llvm-$LLVM_MACOS_VERSION-fdiv-$LLVM_MACOS_REVISION-$architecture-macos"
parent=${ABLA_MACOS_LLVM_CACHE:-$HOME/.local/share/abla/llvm}
prefix="$parent/$name"
mkdir -p "$parent"
if [[ ! -f $prefix/.abla-archive-sha256 || $(cat "$prefix/.abla-archive-sha256") != "$expected" ]]; then
    [[ ! -e $prefix ]] || { echo "install-macos-llvm: refusing inconsistent cache $prefix" >&2; exit 1; }
    work=$(mktemp -d "$parent/.download.XXXXXX")
    trap 'rm -rf -- "$work"' EXIT
    url="https://github.com/AndreBaltazar8/llvm-project/releases/download/$LLVM_MACOS_TAG/$name.tar.xz"
    curl --fail --location --retry 3 "$url" -o "$work/$name.tar.xz"
    printf '%s  %s\n' "$expected" "$work/$name.tar.xz" | shasum -a 256 --check
    tar -xJf "$work/$name.tar.xz" -C "$work"
    test "$(head -n 1 "$work/$name/SOURCE")" = "$name"
    grep -Fq "$LLVM_MACOS_PATCH_SHA256  nix/llvm-instcombine-fdiv-zero.patch" "$work/$name/SOURCE"
    printf '%s\n' "$expected" > "$work/$name/.abla-archive-sha256"
    mv "$work/$name" "$prefix"
fi
test "$("$prefix/bin/llvm-config" --version)" = "$LLVM_MACOS_VERSION"
test -e "$prefix/lib/libLLVM.dylib"
for tool in opt llc clang ld.lld ld64.lld wasm-ld; do
    test -x "$prefix/bin/$tool"
done
# OpenSSL and Binaryen keep their existing Homebrew installation path. LLVM
# itself always comes from the immutable archive above, on both Mac hosts.
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
for formula in openssl@3 binaryen; do
    if ! brew list --versions "$formula" >/dev/null 2>&1; then
        brew install --force-bottle "$formula"
    fi
done
{
    echo "ABLA_LLVM=$prefix"
    echo "ABLA_LLD=$prefix"
    echo "ABLA_LLVM_TOOLS=$prefix/bin"
    echo "ABLA_MACOS_CLANG=$prefix/bin/clang"
} >> "$GITHUB_ENV"
{
    echo "$prefix/bin"
    echo "$(brew --prefix openssl@3)/bin"
    echo "$(brew --prefix binaryen)/bin"
} >> "$GITHUB_PATH"
# Checking opt here also catches an accidental substitution after publication.
OPT="$prefix/bin/opt" "$root/tools/test-llvm-miscompiles.sh"
