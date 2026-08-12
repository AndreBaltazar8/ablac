#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output=${1:-$project_root/build/ablac.bin}
version=v0.2.0
platform=$(uname -s)
machine=$(uname -m)
case "$platform/$machine" in
    Linux/x86_64)
        version=v0.2.2
        artifact=ablac-x86_64-linux
        platform_sha256=19496b965c519682e4d278a50f0f9bad59bdb613903e288ac977f0bda4f9c6a2
        ;;
    Darwin/x86_64)
        artifact=ablac-x86_64-macos
        platform_sha256=8852cd6c82b77c3e1758122f50ee3f59593767660f134742c66c005da2715caa
        ;;
    Darwin/arm64)
        version=v0.2.1
        artifact=ablac-arm64-macos
        platform_sha256=6c37454497cadbe8a43263d837b943f61a30edb06051fe865b07508e9106bb1e
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
