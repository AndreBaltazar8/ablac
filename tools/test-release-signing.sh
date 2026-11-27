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
# The whole directory is checked too: a listed file that is missing is a refusal (v0.2.73 listed its own empty temporary
# list; exactly that line is tolerated, nothing else).
fresh; rm "$work/rel/abla-toolchain-x86_64-linux.tar.gz"
refuses 'a listed asset that is missing (whole directory)' "$work/rel"
ghost() { # the v0.2.73 line, signed again with the good key
    rm -f "$work/rel/SHA256SUMS.sig"
    printf '%s  %s\n' "$1" "$2" >> "$work/rel/SHA256SUMS"
    ssh-keygen -Y sign -f "$work/good" -n abla-release "$work/rel/SHA256SUMS" >/dev/null 2>&1
}
fresh; ghost e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 SHA256SUMS.tmp
accepts "$work/rel"
fresh; ghost 0000000000000000000000000000000000000000000000000000000000000000 SHA256SUMS.tmp
refuses 'a missing SHA256SUMS.tmp with another hash' "$work/rel"
fresh; ghost e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 other.tmp
refuses 'a missing file with the hash of nothing' "$work/rel"
# v0.2.67's two lines as published: release-check's empty marker and a partial temporary list.
fresh; ghost e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 .release-check
ghost ab186c87ae549a4a732441f983e56f70b09770bc0260ef83db103d1914e7e9dd SHA256SUMS.tmp
accepts "$work/rel"
fresh; ghost 0000000000000000000000000000000000000000000000000000000000000000 .release-check
refuses 'a missing .release-check with another hash' "$work/rel"
fresh; ghost ab186c87ae549a4a732441f983e56f70b09770bc0260ef83db103d1914e7e9dd other.tmp
refuses "a missing file with v0.2.67's list hash under another name" "$work/rel"
echo 'a listed file missing from the directory refused (the v0.2.67-v0.2.73 scratch lines tolerated)'

# The key table (tools/release-signing-keys) and --version, after a rotation: 1.0.0-1.0.4 signed by the old key ("good"),
# 1.0.5 on by the new one ("bad" here). A release verifies only under its own range's key, and only as the release asked for.
table="$work/table"; mkdir -p "$table/tools"
cp "$root/tools/verify-release.sh" "$table/tools/"
cp "$work/good.pub" "$table/release-signing.pub"
printf '# a comment\n1.0.0 1.0.4 %s\n1.0.5 - %s\n' "$(cat "$work/good.pub")" "$(cat "$work/bad.pub")" > "$table/tools/release-signing-keys"
release() { # version, key, [bill of materials names...]
    local version=$1 key=$2; shift 2
    rm -rf "$work/vrel"; mkdir "$work/vrel"
    printf 'compiler %s\n' "$version" > "$work/vrel/ablac-x86_64-linux"
    local names=("$@"); ((${#names[@]})) || names=("ablac-$version.spdx.json")
    for name in "${names[@]}"; do printf '{}\n' > "$work/vrel/$name"; done
    (cd "$work/vrel" && if command -v sha256sum >/dev/null 2>&1; then sha256sum ablac-x86_64-linux "${names[@]}"; else shasum -a 256 ablac-x86_64-linux "${names[@]}"; fi > SHA256SUMS)
    ssh-keygen -Y sign -f "$key" -n abla-release "$work/vrel/SHA256SUMS" >/dev/null 2>&1
}
tverify() { "$table/tools/verify-release.sh" --version "$@" > "$work/out" 2>&1; }
taccepts() { tverify "$@" || { cat "$work/out" >&2; fail "the key table refused: $*"; }; }
trefuses() {
    local what=$1; shift
    if tverify "$@"; then fail "the key table accepted $what"; fi
    grep -q REFUSED "$work/out" || { cat "$work/out" >&2; fail "$what: no refusal message"; }
}
release 1.0.3 "$work/good"; taccepts 1.0.3 "$work/vrel"; taccepts v1.0.3 "$work/vrel" ablac-x86_64-linux
release 1.0.3 "$work/bad"; trefuses 'an old release signed by the new key' 1.0.3 "$work/vrel"
release 1.0.6 "$work/bad"; taccepts 1.0.6 "$work/vrel"
release 1.0.6 "$work/good"; trefuses 'a later release signed by the old key' 1.0.6 "$work/vrel"
release 1.0.4 "$work/good"; taccepts 1.0.4 "$work/vrel"
release 1.0.5 "$work/good"; trefuses 'the first release of the new range signed by the old key' 1.0.5 "$work/vrel"
release 0.9.0 "$work/good"; trefuses 'a version in no range' 0.9.0 "$work/vrel"
trefuses 'a version that is not one' latest "$work/vrel"
release 1.0.3 "$work/good"; trefuses "1.0.3's signed files asked for as 1.0.4" 1.0.4 "$work/vrel"
release 1.0.3 "$work/good" other.txt; trefuses 'a signed list without a bill of materials' 1.0.3 "$work/vrel"
release 1.0.3 "$work/good" ablac-1.0.3.spdx.json ablac-1.0.2.spdx.json; trefuses 'a signed list with two bills of materials' 1.0.3 "$work/vrel"
printf '1.0.0 - %s\n1.0.3 - %s\n' "$(cat "$work/good.pub")" "$(cat "$work/bad.pub")" > "$table/tools/release-signing-keys"
release 1.0.3 "$work/good"; trefuses 'a version in two ranges that overlap' 1.0.3 "$work/vrel"
# The repository's own table: one open row, its key release-signing.pub, the first row's FIRST tools/first-signed-release.
rows=$(grep -v '^[[:space:]]*\(#\|$\)' "$root/tools/release-signing-keys")
[[ $(awk '$2 == "-"' <<< "$rows" | wc -l) -eq 1 ]] || fail 'tools/release-signing-keys has no single open row'
[[ $(awk '$2 == "-" { $1 = ""; $2 = ""; sub(/^  /, ""); print }' <<< "$rows") == "$(cat "$root/release-signing.pub")" ]] ||
    fail "the open row's key in tools/release-signing-keys is not release-signing.pub"
[[ $(head -n 1 <<< "$rows" | awk '{ print $1 }') == "$(head -n 1 "$root/tools/first-signed-release" | sed 's/^v//')" ]] ||
    fail "the first row of tools/release-signing-keys does not start at tools/first-signed-release"
echo 'key table: each release under its own range key only, as the release asked for; the repository table matches release-signing.pub'

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
printf '0.0.1 - %s\n' "$(cat "$work/good.pub")" > "$local_root/tools/release-signing-keys"
if command -v git >/dev/null 2>&1; then
    mkdir -p "$local_root/tools" "$local_root/nix"
    cp "$root/tools/bootstrap-compiler.sh" "$root/tools/xtensa-companions.json" "$root/tools/llvm-linux-portable-pins.sh" "$root/tools/llvm-macos-pins.sh" "$local_root/tools/"
    cp "$root/nix/llvm-fork.nix" "$root/nix/nixpkgs.nix" "$root/nix/llvm-instcombine-fdiv-zero.patch" "$root/nix/llvm-windows-static-pin.json" "$local_root/nix/"
    mkdir -p "$local_root/.github/actions/install-nix"
    cp "$root/.github/actions/install-nix/action.yml" "$local_root/.github/actions/install-nix/"
    git -C "$local_root" init -q -b master
    git -C "$local_root" -c user.name=t -c user.email=t@t add -A
    git -C "$local_root" -c user.name=t -c user.email=t@t commit -q -m start
    fresh; rm -f "$work/rel/SHA256SUMS" "$work/rel/SHA256SUMS.sig"
    : > "$work/rel/.release-check"
    (cd "$local_root" && ABLA_RELEASE_SIGNING_KEY_FILE="$work/good" tools/sign-release.sh "$work/rel" --tag v9.9.9) > "$work/out" 2>&1 || { cat "$work/out" >&2; fail 'sign-release.sh failed on a local directory'; }
    [[ -f $work/rel/ablac-9.9.9.spdx.json && -f $work/rel/SHA256SUMS.sig ]] || fail 'sign-release.sh wrote no SBOM or signature'
    [[ ! -e $work/rel/.release-check ]] || fail 'sign-release.sh kept the release-check marker'
    ! grep -Fq '.release-check' "$work/rel/SHA256SUMS" "$work/rel/ablac-9.9.9.spdx.json" || fail 'the release-check marker was listed as an asset'
    grep -q 'ablac-9.9.9.spdx.json' "$work/rel/SHA256SUMS" || fail 'the SBOM is not in SHA256SUMS'
    # Neither list names a scratch file: nothing of the signer's own temporary files is signed.
    ! grep -q '\.tmp' "$work/rel/SHA256SUMS" || fail 'SHA256SUMS lists a temporary file'
    ! grep -q '\.tmp' "$work/rel/ablac-9.9.9.spdx.json" || fail 'the SBOM lists a temporary file'
    accepts "$work/rel"
    # The Windows toolchain zip is an ordinary asset: signed in SHA256SUMS, listed in the SBOM, whose Windows LLVM entry comes from the pin.
    fresh; rm -f "$work/rel/SHA256SUMS" "$work/rel/SHA256SUMS.sig"
    printf 'zip bytes\n' > "$work/rel/abla-toolchain-x86_64-windows.zip"
    printf '%s  abla-toolchain-x86_64-windows.zip\n' "$(sha256sum "$work/rel/abla-toolchain-x86_64-windows.zip" | cut -d' ' -f1)" > "$work/rel/abla-toolchain-x86_64-windows.zip.sha256"
    (cd "$local_root" && ABLA_RELEASE_SIGNING_KEY_FILE="$work/good" tools/sign-release.sh "$work/rel" --tag v9.9.9) > "$work/out" 2>&1 || { cat "$work/out" >&2; fail 'sign-release.sh refused a directory with the Windows zip'; }
    grep -q ' abla-toolchain-x86_64-windows.zip$' "$work/rel/SHA256SUMS" || fail 'the Windows zip is not in SHA256SUMS'
    grep -q '"fileName": "abla-toolchain-x86_64-windows.zip"' "$work/rel/ablac-9.9.9.spdx.json" || fail 'the Windows zip is not in the SBOM'
    grep -q 'SPDXRef-llvm-windows-x86-64' "$work/rel/ablac-9.9.9.spdx.json" || fail 'the SBOM has no Windows LLVM package'
    grep -q 'SPDXRef-nix' "$work/rel/ablac-9.9.9.spdx.json" || fail 'the SBOM has no Nix installer package'
    # Trust roots are declared as external, and the SBOM omits the former hosted TLS dependency.
    grep -q '"SPDXID": "SPDXRef-trust-roots".*not shipped' "$work/rel/ablac-9.9.9.spdx.json" || fail 'the SBOM does not say the trust roots are not shipped'
    ! grep -q SPDXRef-openssl "$work/rel/ablac-9.9.9.spdx.json" || fail "the SBOM still claims an OpenSSL runtime dependency"
    rm -f "$work/rel/ablac-dynamic-x86_64-linux" "$work/rel/SHA256SUMS" "$work/rel/SHA256SUMS.sig"
    (cd "$local_root" && ABLA_RELEASE_SIGNING_KEY_FILE="$work/good" tools/sign-release.sh "$work/rel" --tag v9.9.9) > "$work/out" 2>&1 || { cat "$work/out" >&2; fail 'sign-release.sh failed again'; }
    accepts "$work/rel"
    printf 'keep this file\n' > "$work/rel/.release-check"
    if "$local_root/tools/sign-release.sh" "$work/rel" "$work/good" > "$work/out" 2>&1; then fail 'sign-release.sh accepted a nonempty release-check marker'; fi
    grep -Fxq 'keep this file' "$work/rel/.release-check" || fail 'sign-release.sh changed the nonempty release-check marker'
    rm "$work/rel/.release-check"
    printf 'x' > "$work/rel/static-suite-source.sha"
    if "$root/tools/sign-release.sh" "$work/rel" "$work/good" > "$work/out" 2>&1; then fail 'sign-release.sh signed a directory with static-suite-source.sha'; fi
    echo 'local signing: SBOM and signature written into the directory and verified; the marker file is refused'
fi

# tools/bootstrap-compiler.sh: a signed download is accepted, an unsigned, tampered or foreign-signed one refused, in a
# copy of the tooling whose release-signing.pub is the test key.
proj="$work/proj"; mkdir -p "$proj/tools" "$work/serve"
cp "$root/tools/bootstrap-compiler.sh" "$root/tools/verify-release.sh" "$root/tools/first-signed-release" "$proj/tools/"
cp "$work/good.pub" "$proj/release-signing.pub"
printf '0.0.1 - %s\n' "$(cat "$work/good.pub")" > "$proj/tools/release-signing-keys"
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
        printf '{}\n' > "$work/serve/ablac-${2:-9.9.9}.spdx.json"
        (cd "$work/serve" && if command -v sha256sum >/dev/null 2>&1; then sha256sum "$artifact" "ablac-${2:-9.9.9}.spdx.json"; else shasum -a 256 "$artifact" "ablac-${2:-9.9.9}.spdx.json"; fi > SHA256SUMS)
        [[ -z ${1:-} ]] || ssh-keygen -Y sign -f "$1" -n abla-release "$work/serve/SHA256SUMS" >/dev/null 2>&1
        sum=$(awk -v n="$artifact" '$2 == n { print $1 }' "$work/serve/SHA256SUMS")
    }
    bootstrap() { rm -f "$work/seed.bin"; ABLA_BOOTSTRAP_URL="file://$work/serve/$artifact" ABLA_BOOTSTRAP_SHA256="$sum" ABLA_BOOTSTRAP_REQUIRE_SIGNATURE=1 "$proj/tools/bootstrap-compiler.sh" "$work/seed.bin" > "$work/out" 2>&1; }
    seed "$work/good"; bootstrap || { cat "$work/out" >&2; fail "bootstrap-compiler.sh refused a signed seed"; }
    seed; bootstrap && fail "bootstrap-compiler.sh accepted an unsigned seed"
    seed "$work/bad"; bootstrap && fail "bootstrap-compiler.sh accepted a seed signed by another key"
    seed "$work/good"; printf 'x' >> "$work/serve/$artifact"; sum=$(if command -v sha256sum >/dev/null 2>&1; then sha256sum "$work/serve/$artifact"; else shasum -a 256 "$work/serve/$artifact"; fi | cut -d' ' -f1)
    bootstrap && fail "bootstrap-compiler.sh accepted a tampered seed whose own checksum was updated"
    # Another release's signed files (its bill of materials names 9.9.8) served for the 9.9.9 the script pins.
    seed "$work/good" 9.9.8; bootstrap && fail "bootstrap-compiler.sh accepted the signed files of another release"
    echo 'bootstrap-compiler.sh: signed seed accepted; unsigned, foreign-signed, tampered and another release refused'
fi
echo 'release signing: good accepted; tampering, foreign keys, missing and extra files refused'
