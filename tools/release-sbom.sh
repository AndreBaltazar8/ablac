#!/usr/bin/env bash
# An SPDX 2.3 (JSON) software bill of materials for a release, from what the checkout of the release's commit
# records: the release assets with their sha256, the compiler's own sources (standard library, runtime), the pinned
# LLVM inputs (the fork's commit and patch, the prebuilt Linux and macOS archives, the Xtensa companion), the nixpkgs
# commit and the bootstrap seed. Nothing is fetched; no Python.
#
#   tools/release-sbom.sh TAG ASSETS_DIR OUTPUT.spdx.json
#
# Run it from the release's checkout; it lists every file of ASSETS_DIR (before SHA256SUMS is made, so the SBOM is
# one of the signed assets).
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(cd -- "$here/.." && pwd)
tag=${1:?usage: release-sbom.sh TAG ASSETS_DIR OUTPUT}
assets=${2:?usage: release-sbom.sh TAG ASSETS_DIR OUTPUT}
output=${3:?usage: release-sbom.sh TAG ASSETS_DIR OUTPUT}
[[ $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "release-sbom: tag must look like v0.2.51" >&2; exit 2; }
version=${tag#v}
commit=$(git -C "$root" rev-parse HEAD)

# `NAME=value` of a shell pins file; a quoted nix string; a JSON string field of an object.
shellvar() { sed -n "s/^$2=//p" "$1" | head -n 1; }
nixvar() { sed -n "s/^[[:space:]]*$2 = \"\\(.*\\)\";.*/\\1/p" "$1" | head -n 1; }
sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

llvm_fork_commit=$(nixvar "$root/nix/llvm-fork.nix" 'commit')
llvm_fork_sha=$(nixvar "$root/nix/llvm-fork.nix" 'sha256')
nixpkgs_url=$(nixvar "$root/nix/nixpkgs.nix" 'url')
nixpkgs_commit=$(printf '%s' "$nixpkgs_url" | sed -n 's|.*/archive/\(.*\)\.tar\.gz|\1|p')
patch_sha=$(sha256 "$root/nix/llvm-instcombine-fdiv-zero.patch")
portable_tag=$(shellvar "$root/tools/llvm-linux-portable-pins.sh" LLVM_LINUX_PORTABLE_TAG)
portable_sha=$(shellvar "$root/tools/llvm-linux-portable-pins.sh" LLVM_LINUX_PORTABLE_SHA256)
macos_version=$(shellvar "$root/tools/llvm-macos-pins.sh" LLVM_MACOS_VERSION)
macos_revision=$(shellvar "$root/tools/llvm-macos-pins.sh" LLVM_MACOS_REVISION)
macos_tag=$(shellvar "$root/tools/llvm-macos-pins.sh" LLVM_MACOS_TAG)
macos_arm64=$(shellvar "$root/tools/llvm-macos-pins.sh" LLVM_MACOS_ARM64_SHA256)
macos_x86_64=$(shellvar "$root/tools/llvm-macos-pins.sh" LLVM_MACOS_X86_64_SHA256)
seed_version=$(sed -n 's/^version=//p' "$root/tools/bootstrap-compiler.sh" | head -n 1)
seed_linux=$(awk '/^        artifact=ablac-x86_64-linux$/ { want = 1; next } want && /platform_sha256=/ { sub(/.*platform_sha256=/, ""); print; exit }' "$root/tools/bootstrap-compiler.sh")
# The newest published Xtensa companion release of the catalog: its LLVM version and source commit.
companion=$(awk '/^    "[0-9][^"]*": \{/ { name = $1; gsub(/[":]/, "", name) } /"status": "published"/ { last = name } END { print last }' "$root/tools/xtensa-companions.json")
companion_llvm=$(awk -v n="$companion" '$1 == "\"" n "\":" { on = 1 } on && /"llvmVersion"/ { gsub(/[",]/, "", $2); print $2; exit }' "$root/tools/xtensa-companions.json")
companion_commit=$(awk -v n="$companion" '$1 == "\"" n "\":" { on = 1 } on && /"sourceCommit"/ { gsub(/[",]/, "", $2); print $2; exit }' "$root/tools/xtensa-companions.json")
for required in llvm_fork_commit nixpkgs_commit seed_version portable_tag macos_version companion companion_commit; do
    [[ -n ${!required} ]] || { echo "release-sbom: could not read $required from the checkout" >&2; exit 1; }
done

created=$(date -u +%Y-%m-%dT%H:%M:%SZ)
{
    printf '{\n  "spdxVersion": "SPDX-2.3",\n  "dataLicense": "CC0-1.0",\n  "SPDXID": "SPDXRef-DOCUMENT",\n'
    printf '  "name": "ablac-%s",\n' "$version"
    printf '  "documentNamespace": "https://github.com/AndreBaltazar8/ablac/releases/tag/%s/sbom-%s",\n' "$tag" "$commit"
    printf '  "creationInfo": {"created": "%s", "creators": ["Tool: ablac tools/release-sbom.sh"]},\n' "$created"
    printf '  "documentDescribes": ["SPDXRef-ablac"],\n'
    printf '  "packages": [\n'
    printf '    {"SPDXID": "SPDXRef-ablac", "name": "ablac", "versionInfo": "%s", "supplier": "Person: André Baltazar", "downloadLocation": "git+https://github.com/AndreBaltazar8/ablac@%s", "filesAnalyzed": false, "licenseConcluded": "MPL-2.0", "licenseDeclared": "MPL-2.0", "copyrightText": "NOASSERTION", "comment": "The compiler, its standard library and its runtime (all in this repository), as the release assets below."},\n' "$version" "$commit"
    printf '    {"SPDXID": "SPDXRef-llvm-fork", "name": "llvm-project (AndreBaltazar8 fork: Xtensa backend and the InstCombine fdiv fix)", "versionInfo": "%s", "downloadLocation": "https://github.com/AndreBaltazar8/llvm-project/archive/%s.tar.gz", "filesAnalyzed": false, "checksums": [{"algorithm": "SHA256", "checksumValue": "%s", "comment": "nix fetchzip hash (nix base32) of the archive"}], "licenseConcluded": "Apache-2.0 WITH LLVM-exception", "licenseDeclared": "Apache-2.0 WITH LLVM-exception", "copyrightText": "NOASSERTION", "comment": "nix/llvm-fork.nix; patch nix/llvm-instcombine-fdiv-zero.patch sha256 %s"},\n' "$llvm_fork_commit" "$llvm_fork_commit" "$llvm_fork_sha" "$patch_sha"
    printf '    {"SPDXID": "SPDXRef-llvm-portable-linux", "name": "llvm-23 prebuilt for Linux (portable archive)", "versionInfo": "%s", "downloadLocation": "https://github.com/AndreBaltazar8/llvm-project/releases/tag/%s", "filesAnalyzed": false, "checksums": [{"algorithm": "SHA256", "checksumValue": "%s"}], "licenseConcluded": "Apache-2.0 WITH LLVM-exception", "licenseDeclared": "Apache-2.0 WITH LLVM-exception", "copyrightText": "NOASSERTION"},\n' "$portable_tag" "$portable_tag" "$portable_sha"
    printf '    {"SPDXID": "SPDXRef-llvm-macos-arm64", "name": "llvm %s-fdiv-%s prebuilt for Apple Silicon", "versionInfo": "%s", "downloadLocation": "https://github.com/AndreBaltazar8/llvm-project/releases/tag/%s", "filesAnalyzed": false, "checksums": [{"algorithm": "SHA256", "checksumValue": "%s"}], "licenseConcluded": "Apache-2.0 WITH LLVM-exception", "licenseDeclared": "Apache-2.0 WITH LLVM-exception", "copyrightText": "NOASSERTION"},\n' "$macos_version" "$macos_revision" "$macos_version" "$macos_tag" "$macos_arm64"
    printf '    {"SPDXID": "SPDXRef-llvm-macos-x86-64", "name": "llvm %s-fdiv-%s prebuilt for Intel macOS", "versionInfo": "%s", "downloadLocation": "https://github.com/AndreBaltazar8/llvm-project/releases/tag/%s", "filesAnalyzed": false, "checksums": [{"algorithm": "SHA256", "checksumValue": "%s"}], "licenseConcluded": "Apache-2.0 WITH LLVM-exception", "licenseDeclared": "Apache-2.0 WITH LLVM-exception", "copyrightText": "NOASSERTION"},\n' "$macos_version" "$macos_revision" "$macos_version" "$macos_tag" "$macos_x86_64"
    printf '    {"SPDXID": "SPDXRef-xtensa-companion", "name": "abla Xtensa LLVM companion (optional, installed explicitly)", "versionInfo": "%s", "downloadLocation": "git+https://github.com/AndreBaltazar8/llvm-project@%s", "filesAnalyzed": false, "licenseConcluded": "Apache-2.0 WITH LLVM-exception", "licenseDeclared": "Apache-2.0 WITH LLVM-exception", "copyrightText": "NOASSERTION", "comment": "LLVM %s; its archives and checksums are pinned in tools/xtensa-companions.json"},\n' "$companion" "$companion_commit" "$companion_llvm"
    printf '    {"SPDXID": "SPDXRef-nixpkgs", "name": "nixpkgs (the Linux build environment)", "versionInfo": "%s", "downloadLocation": "%s", "filesAnalyzed": false, "licenseConcluded": "MIT", "licenseDeclared": "MIT", "copyrightText": "NOASSERTION", "comment": "nix/nixpkgs.nix; supplies the C toolchain, lld, compiler-rt, OpenSSL and the other Linux inputs, not shipped in the static assets except compiler-rt builtins and the statically linked LLVM and lld"},\n' "$nixpkgs_commit" "$nixpkgs_url"
    printf '    {"SPDXID": "SPDXRef-seed", "name": "ablac bootstrap seed", "versionInfo": "%s", "downloadLocation": "https://github.com/AndreBaltazar8/ablac/releases/tag/v%s", "filesAnalyzed": false, "checksums": [{"algorithm": "SHA256", "checksumValue": "%s", "comment": "ablac-x86_64-linux"}], "licenseConcluded": "MPL-2.0", "licenseDeclared": "MPL-2.0", "copyrightText": "NOASSERTION", "comment": "tools/bootstrap-compiler.sh; the compiler that builds this release (stage 1)"}\n' "$seed_version" "${seed_version#v}" "$seed_linux"
    printf '  ],\n  "files": [\n'
    first=1
    while IFS= read -r path; do
        name=${path#"$assets"/}
        id=$(printf '%s' "$name" | sed 's/[^A-Za-z0-9.-]/-/g')
        ((first)) || printf ',\n'
        first=0
        printf '    {"SPDXID": "SPDXRef-file-%s", "fileName": "%s", "checksums": [{"algorithm": "SHA256", "checksumValue": "%s"}], "licenseConcluded": "NOASSERTION", "copyrightText": "NOASSERTION"}' "$id" "$name" "$(sha256 "$path")"
    done < <(find "$assets" -type f | LC_ALL=C sort)
    printf '\n  ],\n  "relationships": [\n'
    printf '    {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": "SPDXRef-ablac"},\n'
    for dependency in llvm-fork llvm-portable-linux llvm-macos-arm64 llvm-macos-x86-64 xtensa-companion nixpkgs seed; do
        printf '    {"spdxElementId": "SPDXRef-ablac", "relationshipType": "DEPENDS_ON", "relatedSpdxElement": "SPDXRef-%s"},\n' "$dependency"
    done
    first=1
    while IFS= read -r path; do
        name=${path#"$assets"/}
        id=$(printf '%s' "$name" | sed 's/[^A-Za-z0-9.-]/-/g')
        ((first)) || printf ',\n'
        first=0
        printf '    {"spdxElementId": "SPDXRef-ablac", "relationshipType": "CONTAINS", "relatedSpdxElement": "SPDXRef-file-%s"}' "$id"
    done < <(find "$assets" -type f | LC_ALL=C sort)
    printf '\n  ]\n}\n'
} > "$output"
echo "release-sbom: wrote $output ($(grep -c '"fileName"' "$output") assets)"
