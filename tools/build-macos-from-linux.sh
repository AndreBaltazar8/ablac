#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

if [[ $# -lt 3 || $# -gt 4 ]]; then
    printf 'usage: %s <compiler> <source.ab> <output-prefix> [--fast]\n' "$0" >&2
    exit 2
fi
if [[ $(uname -s) != Linux ]]; then
    printf '%s\n' 'build-macos-from-linux.sh requires Linux' >&2
    exit 2
fi
if [[ -z ${ABLA_MACOS_SDK:-} || ! -d $ABLA_MACOS_SDK ]]; then
    printf '%s\n' 'set ABLA_MACOS_SDK to an extracted macOS SDK' >&2
    exit 2
fi
if [[ ${4:-} != "" && ${4:-} != "--fast" ]]; then
    printf 'unsupported option: %s\n' "$4" >&2
    exit 2
fi

compiler=$1
source=$2
output_prefix=$3
profile=${4:-}
mkdir -p -- "$(dirname -- "$output_prefix")"

for architecture in x86_64 arm64; do
    stub_directory="$project_root/build/macos-link-stubs/$architecture"
    "$project_root/tools/prepare-macos-link-stubs.sh" \
        "$architecture" "$stub_directory"
    target="$architecture-macos"
    ABLA_MACOS_LLVM_LIB="$stub_directory" \
    ABLA_MACOS_OPENSSL_LIB="$stub_directory" \
        "$compiler" build "$source" \
        --target "$target" --no-cache ${profile:+"$profile"} \
        -o "$output_prefix-$target"
done

file "$output_prefix-x86_64-macos" "$output_prefix-arm64-macos"
