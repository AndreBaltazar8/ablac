#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 || $# -gt 3 ]]; then
    printf 'usage: %s <compiler> <output> [entry]\n' "$0" >&2
    exit 2
fi

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
# Probe the bootstrap in the same LLVM environment used for the build.
if [[ $(uname -s) != Darwin && -z ${IN_NIX_SHELL:-} ]]; then
    printf -v self_command '%q ' "$project_root/tools/build-self-hosted-current.sh" "$@"
    exec nix-shell "$project_root/shell.nix" --run "$self_command"
fi
if [[ $(uname -s) == Darwin && -n ${ABLA_LLVM:-} ]]; then
    # Released seeds name Homebrew's libLLVM. Give the seed the patched
    # library too; its child build launcher sets this again before exec.
    export DYLD_LIBRARY_PATH="$ABLA_LLVM/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
fi

compiler=$1
if [[ $compiler != /* ]]; then compiler=$project_root/$compiler; fi
output=$2
entry=${3:-src/orc_main.ab}
# Older compilers may need a different OpenSSL or LLVM path. Patch a copy so the
# library paths apply to that compiler alone and are kept out of its child tools.
if [[ -n ${ABLA_LINUX_OPENSSL_LIB:-} ]] && ! "$compiler" --version >/dev/null 2>&1; then
    mkdir -p "$project_root/build"
    located_compiler=$(mktemp "$project_root/build/.bootstrap-located.XXXXXX")
    trap 'rm -f -- "$located_compiler"' EXIT
    cp -f "$compiler" "$located_compiler"
    # (And this shell's libLLVM, after the one it was built with: a pin of another LLVM build moves that path.)
    patchelf --add-rpath "$ABLA_LINUX_OPENSSL_LIB${ABLA_LINUX_LLVM_LIB:+:$ABLA_LINUX_LLVM_LIB}" "$located_compiler"
    chmod +x "$located_compiler"
    compiler=$located_compiler
fi
# v0.2.20 cannot parse the private declarations now used by the library.
# This checkpoint implements private declarations and generics while its own
# library still uses the old syntax. Keep the source transition reproducible
# on every host, including a clean checkout of the v0.2.21 release tag.
if [[ $("$compiler" --version) == "ablac 0.2.20" ]]; then
    mkdir -p "$project_root/build"
    bridge_directory=$(mktemp -d "$project_root/build/bootstrap-language.XXXXXX")
    trap 'rm -rf -- "$bridge_directory" ${located_compiler:+"$located_compiler"}' EXIT
    bridge_revision=773683772ce54bcfae4fdfd7049b55bd28ea1814
    bridge_sha256=0c2024ce8b45c1c6f8b8aaade79998a03752c6c64df6266c211df149d53d9640
    archive="$bridge_directory/source.tar.gz"
    curl --fail --location --retry 3 \
        "https://codeload.github.com/AndreBaltazar8/ablac/tar.gz/$bridge_revision" \
        -o "$archive"
    if command -v sha256sum >/dev/null 2>&1; then
        actual_sha256=$(sha256sum "$archive" | cut -d' ' -f1)
    else
        actual_sha256=$(shasum -a 256 "$archive" | cut -d' ' -f1)
    fi
    if [[ $actual_sha256 != "$bridge_sha256" ]]; then
        echo 'bootstrap language-transition source checksum mismatch' >&2
        exit 1
    fi
    source_directory="$bridge_directory/source"
    mkdir -p "$source_directory"
    tar -xzf "$archive" -C "$source_directory" --strip-components=1
    echo "bootstrapping private declarations and generics through $bridge_revision"
    ABLA_SYSROOT="$source_directory" \
        "$source_directory/tools/build-self-hosted-release.sh" \
        "$compiler" "$bridge_directory/ablac" "$source_directory/src/orc_main.ab"
    compiler="$bridge_directory/ablac"
fi
"$project_root/tools/build-self-hosted-release.sh" \
    "$compiler" "$output" "$entry"
