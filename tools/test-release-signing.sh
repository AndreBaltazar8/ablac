#!/usr/bin/env bash
# Release signing: a signed release verifies, and every kind of tampering is refused (tools/sign-release.sh,
# tools/verify-release.sh). Uses throwaway keys; the real private key never leaves the Actions secret.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/test-release-signing.XXXXXX")
trap 'rm -rf -- "$work"' EXIT
fail() { printf 'release-signing: %s\n' "$*" >&2; exit 1; }
accepts() { "$root/tools/verify-release.sh" --key "$work/good.pub" "$@" > "$work/out" 2>&1 || { cat "$work/out" >&2; fail "refused a good release: $*"; }; }
refuses() {
    local what=$1; shift
    if "$root/tools/verify-release.sh" --key "$work/good.pub" "$@" > "$work/out" 2>&1; then fail "accepted $what"; fi
    grep -q REFUSED "$work/out" || { cat "$work/out" >&2; fail "$what: no refusal message"; }
}

ssh-keygen -q -t ed25519 -N '' -C 'test release' -f "$work/good" >/dev/null
ssh-keygen -q -t ed25519 -N '' -C 'attacker' -f "$work/bad" >/dev/null
fresh() {
    rm -rf "$work/rel"; mkdir "$work/rel"
    printf 'compiler bytes\n' > "$work/rel/ablac-x86_64-linux"
    printf 'toolchain bytes\n' > "$work/rel/abla-toolchain-x86_64-linux.tar.gz"
    printf 'abc  ablac-x86_64-linux\n' > "$work/rel/ablac-x86_64-linux.sha256"
    # sign-release.sh checks against the repository's key: sign with the test key and verify with it.
    (cd "$work/rel" && find . -type f | LC_ALL=C sort | sed 's|^\./||' | while IFS= read -r n; do
        if command -v sha256sum >/dev/null 2>&1; then sha256sum "$n"; else shasum -a 256 "$n"; fi; done > SHA256SUMS)
    ssh-keygen -Y sign -f "${1:-$work/good}" -n abla-release "$work/rel/SHA256SUMS" >/dev/null 2>&1
}

fresh
accepts "$work/rel"
accepts "$work/rel" ablac-x86_64-linux
echo 'good release accepted'

fresh; printf 'tampered\n' >> "$work/rel/ablac-x86_64-linux"
refuses 'a tampered asset' "$work/rel"
refuses 'a tampered asset by name' "$work/rel" ablac-x86_64-linux
echo 'tampered asset refused'

fresh; sed -i.bak 's/^[0-9a-f]\{64\}/0000000000000000000000000000000000000000000000000000000000000000/' "$work/rel/SHA256SUMS"; rm -f "$work/rel/SHA256SUMS.bak"
refuses 'a modified SHA256SUMS (the signature no longer matches)' "$work/rel"
echo 'modified SHA256SUMS refused'

fresh "$work/bad"
refuses 'a release signed by another key' "$work/rel"
echo 'foreign signature refused'

fresh; rm "$work/rel/SHA256SUMS.sig"
refuses 'a release without a signature' "$work/rel"
fresh; rm "$work/rel/SHA256SUMS"
refuses 'a release without SHA256SUMS' "$work/rel"
echo 'unsigned release refused'

fresh; printf 'extra\n' > "$work/rel/extra-asset"
refuses 'an asset the signature does not list' "$work/rel"
refuses 'a name that is not listed' "$work/rel" extra-asset
fresh; rm "$work/rel/abla-toolchain-x86_64-linux.tar.gz"
refuses 'a listed asset that is missing (by name)' "$work/rel" abla-toolchain-x86_64-linux.tar.gz
echo 'extra and missing assets refused'

# The real signer: sign-release.sh signs a directory and verifies it against the repository's public key, so with
# a key that is not the project's it must refuse (the guard against shipping with the wrong secret).
fresh; rm "$work/rel/SHA256SUMS" "$work/rel/SHA256SUMS.sig"
if "$root/tools/sign-release.sh" "$work/rel" "$work/good" > "$work/out" 2>&1; then fail "sign-release.sh accepted a key that is not release-signing.pub"; fi
grep -q REFUSED "$work/out" || fail "sign-release.sh: no refusal for a foreign key"
# The local flow: sign-release.sh with a key file (argument, or ABLA_RELEASE_SIGNING_KEY_FILE) and --tag writes the SBOM,
# SHA256SUMS and the signature into the directory; with the repository's own public key the throwaway key is refused (the
# wrong-key guard), and a directory with the static-suite marker is refused. The positive local case uses a copy of the
# tooling whose release-signing.pub is the test key.
local_root="$work/local-root"; mkdir -p "$local_root/tools" "$local_root/nix"
cp "$root/tools/sign-release.sh" "$root/tools/verify-release.sh" "$root/tools/release-sbom.sh" "$local_root/tools/"
cp "$work/good.pub" "$local_root/release-signing.pub"
if command -v git >/dev/null 2>&1; then
    mkdir -p "$local_root/tools" "$local_root/nix"
    cp "$root/tools/bootstrap-compiler.sh" "$root/tools/xtensa-companions.json" "$root/tools/llvm-linux-portable-pins.sh" "$root/tools/llvm-macos-pins.sh" "$local_root/tools/"
    cp "$root/nix/llvm-fork.nix" "$root/nix/nixpkgs.nix" "$root/nix/llvm-instcombine-fdiv-zero.patch" "$local_root/nix/"
    git -C "$local_root" init -q -b master
    git -C "$local_root" -c user.name=t -c user.email=t@t add -A
    git -C "$local_root" -c user.name=t -c user.email=t@t commit -q -m start
    fresh; rm -f "$work/rel/SHA256SUMS" "$work/rel/SHA256SUMS.sig"
    (cd "$local_root" && ABLA_RELEASE_SIGNING_KEY_FILE="$work/good" tools/sign-release.sh "$work/rel" --tag v9.9.9) > "$work/out" 2>&1 || { cat "$work/out" >&2; fail 'sign-release.sh failed on a local directory'; }
    [[ -f $work/rel/ablac-9.9.9.spdx.json && -f $work/rel/SHA256SUMS.sig ]] || fail 'sign-release.sh wrote no SBOM or signature'
    grep -q 'ablac-9.9.9.spdx.json' "$work/rel/SHA256SUMS" || fail 'the SBOM is not in SHA256SUMS'
    accepts "$work/rel"
    printf 'x' > "$work/rel/static-suite-source.sha"
    if "$root/tools/sign-release.sh" "$work/rel" "$work/good" > "$work/out" 2>&1; then fail 'sign-release.sh signed a directory with static-suite-source.sha'; fi
    echo 'local signing: SBOM and signature written into the directory and verified; the marker file is refused'
fi

# tools/bootstrap-compiler.sh: a signed download is accepted, an unsigned, tampered or foreign-signed one refused, in a
# copy of the tooling whose release-signing.pub is the test key.
proj="$work/proj"; mkdir -p "$proj/tools" "$work/serve"
cp "$root/tools/bootstrap-compiler.sh" "$root/tools/verify-release.sh" "$root/tools/first-signed-release" "$proj/tools/"
cp "$work/good.pub" "$proj/release-signing.pub"
sed -i.bak 's/^version=.*/version=v9.9.9/' "$proj/tools/bootstrap-compiler.sh"; rm -f "$proj/tools/bootstrap-compiler.sh.bak"
case "$(uname -s)/$(uname -m)" in
    Linux/x86_64) artifact=ablac-x86_64-linux ;;
    Darwin/x86_64) artifact=ablac-x86_64-macos ;;
    Darwin/arm64) artifact=ablac-arm64-macos ;;
    *) echo 'release signing: bootstrap-compiler.sh checks skipped on this host'; artifact= ;;
esac
if [[ -n $artifact ]]; then
    seed() { # name of the key to sign with, or none
        rm -rf "$work/serve"; mkdir "$work/serve"
        printf '#!/bin/sh\necho seed\n' > "$work/serve/$artifact"
        (cd "$work/serve" && if command -v sha256sum >/dev/null 2>&1; then sha256sum "$artifact"; else shasum -a 256 "$artifact"; fi > SHA256SUMS)
        [[ -z ${1:-} ]] || ssh-keygen -Y sign -f "$1" -n abla-release "$work/serve/SHA256SUMS" >/dev/null 2>&1
        sum=$(cut -d' ' -f1 "$work/serve/SHA256SUMS")
    }
    bootstrap() { rm -f "$work/seed.bin"; ABLA_BOOTSTRAP_URL="file://$work/serve/$artifact" ABLA_BOOTSTRAP_SHA256="$sum" ABLA_BOOTSTRAP_REQUIRE_SIGNATURE=1 "$proj/tools/bootstrap-compiler.sh" "$work/seed.bin" > "$work/out" 2>&1; }
    seed "$work/good"; bootstrap || { cat "$work/out" >&2; fail "bootstrap-compiler.sh refused a signed seed"; }
    seed; bootstrap && fail "bootstrap-compiler.sh accepted an unsigned seed"
    seed "$work/bad"; bootstrap && fail "bootstrap-compiler.sh accepted a seed signed by another key"
    seed "$work/good"; printf 'x' >> "$work/serve/$artifact"; sum=$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$work/serve/$artifact"; else shasum -a 256 "$work/serve/$artifact"; fi | cut -d' ' -f1)
    bootstrap && fail "bootstrap-compiler.sh accepted a tampered seed whose own checksum was updated"
    echo 'bootstrap-compiler.sh: signed seed accepted; unsigned, foreign-signed and tampered refused'
fi
echo 'release signing: good accepted; tampering, foreign keys, missing and extra files refused'
