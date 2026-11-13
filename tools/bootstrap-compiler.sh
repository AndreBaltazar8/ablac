#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output=${1:-$project_root/build/ablac.bin}
version=v0.2.58
platform=$(uname -s)
machine=$(uname -m)
case "$platform/$machine" in
    Linux/x86_64)
        artifact=ablac-x86_64-linux
        platform_sha256=3de95d4e46fc43010319cfe619104e683d304e0ffcfb4239b8618de891c4e09e
        ;;
    Darwin/x86_64)
        artifact=ablac-x86_64-macos
        platform_sha256=7ed526114c266e953e545971dcb24dafc5e31ddbc3a91b63297e4d467b0d78c7
        ;;
    Darwin/arm64)
        artifact=ablac-arm64-macos
        platform_sha256=3c2985682c8ed6568a9785d326a9d46a5ff88a2cb863c77e509e67c74aa65668
        ;;
    *)
        printf 'unsupported bootstrap host: %s/%s\n' "$platform" "$machine" >&2
        exit 2
        ;;
esac
url=${ABLA_BOOTSTRAP_URL:-https://github.com/AndreBaltazar8/ablac/releases/download/$version/$artifact}
expected_sha256=${ABLA_BOOTSTRAP_SHA256:-$platform_sha256}

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

mkdir -p -- "$(dirname -- "$output")"
temporary=$(mktemp "${output}.download.XXXXXX")
cleanup() {
    rm -f -- "$temporary"
}
trap cleanup EXIT

if [[ -f $output ]]; then
    actual_sha256=$(sha256 "$output")
    if [[ $actual_sha256 == "$expected_sha256" ]]; then
        chmod +x "$output"
        exit 0
    fi
    printf 'bootstrap compiler checksum mismatch: %s\n' "$output" >&2
    exit 1
fi

printf 'downloading Abla bootstrap compiler %s\n' "$version"
curl --fail --location --retry 3 --output "$temporary" "$url"
actual_sha256=$(sha256 "$temporary")
if [[ $actual_sha256 != "$expected_sha256" ]]; then
    printf 'bootstrap compiler checksum mismatch: expected %s, got %s\n' \
        "$expected_sha256" "$actual_sha256" >&2
    exit 1
fi

chmod +x "$temporary"
mv -f -- "$temporary" "$output"
