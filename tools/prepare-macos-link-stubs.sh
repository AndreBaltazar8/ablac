#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

if [[ $# -lt 1 || $# -gt 2 ]]; then
    printf 'usage: %s <arm64|x86_64> [output-directory]\n' "$0" >&2
    exit 2
fi

architecture=$1
output_directory=${2:-$project_root/build/macos-link-stubs/$architecture}
case "$architecture" in
    arm64)
        target=arm64-apple-macosx11.0.0
        homebrew_prefix=/opt/homebrew
        ;;
    x86_64)
        target=x86_64-apple-macosx11.0.0
        homebrew_prefix=/usr/local
        ;;
    *)
        printf 'unsupported macOS architecture: %s\n' "$architecture" >&2
        exit 2
        ;;
esac

if ! command -v llvm-ifs >/dev/null 2>&1 ||
    ! command -v llvm-config >/dev/null 2>&1; then
    if [[ -n ${IN_NIX_SHELL:-} ]]; then
        printf '%s\n' 'LLVM interface tools are missing from the active nix-shell' >&2
        exit 127
    fi
    printf -v invocation '%q %q %q' "$0" "$architecture" "$output_directory"
    exec nix-shell "$project_root/shell.nix" --run "$invocation"
fi

openssl_library_directory=${ABLA_LINUX_OPENSSL_LIB:-}
if [[ -z $openssl_library_directory ]]; then
    printf '%s\n' 'ABLA_LINUX_OPENSSL_LIB is not configured; use the repository nix-shell' >&2
    exit 2
fi

llvm_library_directory=$(llvm-config --libdir)
temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/abla-macos-stubs.XXXXXX")
cleanup() {
    rm -rf -- "$temporary_directory"
}
trap cleanup EXIT
mkdir -p -- "$output_directory"

make_stub() {
    local source=$1
    local output=$2
    local install_name=$3
    local interface="$temporary_directory/$(basename -- "$output").ifs"

    llvm-ifs --target="$target" --output-ifs="$interface" "$source"
    sed -i \
        -e '/^NeededLibs:/,/^Symbols:/ { /^  - /d; }' \
        -e '/Undefined: true/d' \
        -e 's/^  - { Name: /  - { Name: _/' \
        "$interface"
    llvm-ifs --input-format=IFS --output-tbd="$output" "$interface"
    sed -i \
        "s|install-name:    ''|install-name:    '$install_name'|" \
        "$output"
}

make_stub \
    "$llvm_library_directory/libLLVM.so" \
    "$output_directory/libLLVM.tbd" \
    "$homebrew_prefix/opt/llvm@21/lib/libLLVM.dylib"
make_stub \
    "$openssl_library_directory/libssl.so" \
    "$output_directory/libssl.tbd" \
    "$homebrew_prefix/opt/openssl@3/lib/libssl.3.dylib"
make_stub \
    "$openssl_library_directory/libcrypto.so" \
    "$output_directory/libcrypto.tbd" \
    "$homebrew_prefix/opt/openssl@3/lib/libcrypto.3.dylib"

printf 'prepared %s macOS link stubs in %s\n' \
    "$architecture" "$output_directory"
