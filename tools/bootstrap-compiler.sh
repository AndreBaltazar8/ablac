#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output=${1:-$project_root/build/ablac.bin}
version=v0.2.17
platform=$(uname -s)
machine=$(uname -m)
case "$platform/$machine" in
    Linux/x86_64)
        artifact=ablac-x86_64-linux
        platform_sha256=6a957a8f87a5bb01fbc0294627c1114de02af3928e97c1eabfd9107d2167bc19
        ;;
    Darwin/x86_64)
        artifact=ablac-x86_64-macos
        platform_sha256=75ac3e95e73d323254900417e6fae86000d95486ebd02c3ec85fcd51d1be9ded
        ;;
    Darwin/arm64)
        artifact=ablac-arm64-macos
        platform_sha256=0f9cb219f04cd4ade2715802ea7e79ba7aae3cadfb868fe1b27400b70df6ebc8
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
