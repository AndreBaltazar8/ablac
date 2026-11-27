#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output=${1:-$project_root/build/ablac.bin}
version=v0.2.78
platform=$(uname -s)
machine=$(uname -m)
case "$platform/$machine" in
    Linux/x86_64)
        artifact=ablac-x86_64-linux
        platform_sha256=334959d4198a44871dfaf974f8b446be6ede5d4d0a929eb203665f933f5e608c
        ;;
    Darwin/x86_64)
        artifact=ablac-x86_64-macos
        platform_sha256=4b1054c6ce18178982150e5f2c52c436513cb46ee12df6cd460b015b7e4f35d2
        ;;
    Darwin/arm64)
        artifact=ablac-arm64-macos
        platform_sha256=2491bfffc5d8edafaa78467f47b754265a40dd1d2ce0e22d184ac74b11ff73dd
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

# Releases from tools/first-signed-release on carry SHA256SUMS and SHA256SUMS.sig (ssh-keygen -Y sign with the key of
# release-signing.pub). The download must verify against them, besides matching the pinned sha256 above: no signature, a
# bad one or a different file is a refusal (tools/verify-release.sh). A custom ABLA_BOOTSTRAP_URL has no release to
# check; the pinned (or ABLA_BOOTSTRAP_SHA256) checksum alone judges it, as for earlier releases, unless
# ABLA_BOOTSTRAP_REQUIRE_SIGNATURE=1 asks for the signature beside the URL (the test uses it).
signature_required() {
    [[ ${ABLA_BOOTSTRAP_REQUIRE_SIGNATURE:-} == 1 ]] && return 0
    [[ -z ${ABLA_BOOTSTRAP_URL:-} ]] || return 1
    local first
    first=$(head -n 1 "$project_root/tools/first-signed-release")
    [[ $(printf '%s\n%s\n' "$first" "$version" | sort -V | head -n 1) == "$first" ]]
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

if signature_required; then
    signed=$(mktemp -d)
    trap 'rm -rf -- "$signed"; cleanup' EXIT
    base=${url%/*}
    curl --fail --location --retry 3 --output "$signed/SHA256SUMS" "$base/SHA256SUMS" &&
        curl --fail --location --retry 3 --output "$signed/SHA256SUMS.sig" "$base/SHA256SUMS.sig" ||
        { printf 'bootstrap compiler %s: no signed SHA256SUMS in its release; refusing it\n' "$version" >&2; exit 1; }
    ln -f "$temporary" "$signed/$artifact" 2>/dev/null || cp "$temporary" "$signed/$artifact"
    "$project_root/tools/verify-release.sh" --version "$version" "$signed" "$artifact" >&2 || exit 1
fi

chmod +x "$temporary"
mv -f -- "$temporary" "$output"
