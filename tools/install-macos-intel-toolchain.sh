#!/usr/bin/env bash
# The native toolchain of an Intel macOS runner (llvm@23, lld@23, openssl@3, binaryen): Homebrew no longer builds
# bottles for that configuration, so llvm and lld are the checksum-pinned 23.1.0 Sonoma bottles of homebrew-core.
# The same as the Intel branch of release.yml's "Install the native toolchain" step. Intel macOS only.
# Runs under the system bash 3.2 of the macOS runners: no associative arrays, ${x,,}, ;& or [[ -v ]].
set -euo pipefail
[[ $(uname -s) == Darwin && $(uname -m) == x86_64 ]] || { echo "install-macos-intel-toolchain: Intel macOS only" >&2; exit 2; }
# Homebrew no longer bottles newer LLVM 23 patches for Intel Macs.
# Install its checksum-pinned 23.1.0 Sonoma bottles instead of
# compiling LLVM and its build dependencies from source.
export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
export HOMEBREW_NO_INSTALLED_DEPENDENTS_CHECK=1
for formula in openssl@3 zstd z3 binaryen; do
  if ! brew list --versions "$formula" >/dev/null 2>&1; then
    brew install --force-bottle "$formula"
  fi
done
install_bottle() {
  local formula=$1 checksum=$2 token bottle
  bottle="$RUNNER_TEMP/$formula--23.1.0.sonoma.bottle.tar.gz"
  token=$(curl -fsSL --retry 3 \
    "https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/$formula:pull" |
    sed -n 's/.*"token":"\([^"]*\)".*/\1/p')
  curl -fL --retry 3 -H "Authorization: Bearer $token" \
    "https://ghcr.io/v2/homebrew/core/$formula/blobs/sha256:$checksum" -o "$bottle"
  printf '%s  %s\n' "$checksum" "$bottle" | shasum -a 256 --check
  # Runner images disable local package paths by default; this
  # official bottle has just passed its pinned checksum check.
  env -u HOMEBREW_FORBID_PACKAGES_FROM_PATHS HOMEBREW_DEVELOPER=1 \
    brew install --ignore-dependencies "$bottle"
}
# homebrew-core: llvm 451e4146974a; lld 4c53d1f9e8fe.
install_bottle llvm 0b0168dc611a9d77aaa62d094178297f8a861d647cc59c43a5dc3f76bd6eb7b2
install_bottle lld c8affeb82959e53875d13cd58bc459f75863f17e3d4ad68d4ca939a104fd18d5
prefix=$(brew --prefix)
ln -sfn "$prefix/opt/llvm" "$prefix/opt/llvm@23"
ln -sfn "$prefix/opt/lld" "$prefix/opt/lld@23"
test "$("$prefix/opt/llvm@23/bin/llvm-config" --version)" = 23.1.0
"$prefix/opt/lld@23/bin/wasm-ld" --version
if [[ -n ${GITHUB_PATH:-} ]]; then
    echo "$(brew --prefix)/opt/llvm@23/bin" >> "$GITHUB_PATH"
    echo "$(brew --prefix)/opt/lld@23/bin" >> "$GITHUB_PATH"
    echo "$(brew --prefix openssl@3)/bin" >> "$GITHUB_PATH"
fi
