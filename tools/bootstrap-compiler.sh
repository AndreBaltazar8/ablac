#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
output=${1:-$project_root/build/ablac.bin}
version=v0.2.79
platform=$(uname -s)
machine=$(uname -m)
case "$platform/$machine" in
    Linux/x86_64)
        artifact=ablac-x86_64-linux
        platform_sha256=8c0f67519b46496cdaeeeb15e28ff0abb4a45d58776c2f5a966e77f1e72d00e0
        ;;
    Darwin/x86_64)
        artifact=ablac-x86_64-macos
        platform_sha256=2b3c53ce33ec2ae693c2973e68555c3a7b7e79a92ebfa3fe33f1ae20e771c72a
        ;;
    Darwin/arm64)
        artifact=ablac-arm64-macos
        platform_sha256=4a99d7a4e6d2fa7dd6370e390236eafa2acf1ebd03c082152052819f3bae4470
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
