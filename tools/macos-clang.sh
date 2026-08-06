#!/usr/bin/env bash
set -euo pipefail

if [[ $(uname -s) != Darwin ]]; then
    printf '%s\n' 'macos-clang.sh requires Darwin' >&2
    exit 2
fi

if [[ -x /opt/homebrew/bin/brew ]]; then
    brew_command=/opt/homebrew/bin/brew
elif [[ -x /usr/local/bin/brew ]]; then
    brew_command=/usr/local/bin/brew
else
    printf '%s\n' 'Homebrew is required to locate LLVM on macOS' >&2
    exit 127
fi

llvm_prefix=$($brew_command --prefix llvm@21 2>/dev/null ||
    $brew_command --prefix llvm)
sdk_root=$(xcrun --sdk macosx --show-sdk-path)
exec "$llvm_prefix/bin/clang" \
    -isysroot "$sdk_root" \
    -D_XOPEN_SOURCE=700 \
    -D_DARWIN_C_SOURCE \
    -Wno-deprecated-declarations \
    "$@"
