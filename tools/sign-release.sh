#!/usr/bin/env bash
# Signs a release's assets, in CI (the publish job) or locally (the release flow that checks a publish-off run's
# artifacts and uploads them with `gh release create`): writes the SBOM, then DIR/SHA256SUMS (every file in DIR, sorted,
# as `<sha256>  <name>`) and signs it with ssh-keygen -Y sign (namespace abla-release) into DIR/SHA256SUMS.sig, and
# verifies the result against release-signing.pub (tools/verify-release.sh) so a wrong key never ships.
#
#   tools/sign-release.sh DIR [KEYFILE] [--tag vX.Y.Z]
#
# KEYFILE is the private key (default: the file named by ABLA_RELEASE_SIGNING_KEY_FILE). With --tag the SBOM
# ablac-X.Y.Z.spdx.json is made in DIR first (tools/release-sbom.sh reads the checkout this script is run from, so run
# it from the release commit's checkout). Signing consumes the empty .release-check marker if present. Run
# release-check.sh again with DIR as --artifacts and a separate --out (its `signature` check must PASS), then upload
# every file of DIR. Needs bash, ssh-keygen and sha256sum or shasum.
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }
dir=
key=${ABLA_RELEASE_SIGNING_KEY_FILE:-}
tag=
while (($#)); do
    case $1 in
        --tag) tag=${2:?}; shift 2 ;;
        -h | --help) usage ;;
        -*) echo "sign-release: unknown option $1" >&2; usage ;;
        *) if [[ -z $dir ]]; then dir=$1; else key=$1; fi; shift ;;
    esac
done
[[ -n $dir && -n $key ]] || usage
[[ -d $dir ]] || { echo "sign-release: $dir is not a directory" >&2; exit 2; }
[[ -f $key ]] || { echo "sign-release: no key file $key" >&2; exit 2; }
# The publish job removes this marker of the static suite before signing; a local directory must not keep it either
# (it would be signed and uploaded as an asset).
[[ ! -e $dir/static-suite-source.sha ]] || { echo "sign-release: remove $dir/static-suite-source.sha first (it is not an asset)" >&2; exit 2; }
marker=$dir/.release-check
if [[ -e $marker || -L $marker ]]; then
    [[ -f $marker && ! -L $marker && ! -s $marker ]] || {
        echo "sign-release: $marker is not an empty release-check marker" >&2
        exit 2
    }
    rm -- "$marker"
fi
rm -f "$dir/SHA256SUMS" "$dir/SHA256SUMS.sig"
# Scratch files live outside DIR: inside it the list of DIR's files would list the scratch file itself (the empty
# SHA256SUMS.tmp of v0.2.73's list, the .sbom.tmp of its SBOM).
scratch=$(mktemp -d "${TMPDIR:-/tmp}/sign-release.XXXXXX") || exit 1
trap 'rm -rf -- "$scratch"' EXIT
if [[ -n $tag ]]; then
    rm -f "$dir/ablac-${tag#v}.spdx.json"
    "$here/release-sbom.sh" "$tag" "$dir" "$scratch/sbom.json"
    cp "$scratch/sbom.json" "$dir/ablac-${tag#v}.spdx.json"
fi
(
    cd "$dir"
    find . -type f | LC_ALL=C sort | sed 's|^\./||' | while IFS= read -r name; do
        case $name in */*) echo "sign-release: nested file $name" >&2; exit 1 ;; esac
        if command -v sha256sum >/dev/null 2>&1; then sha256sum "$name"; else shasum -a 256 "$name"; fi
    done > "$scratch/SHA256SUMS"
)
cp "$scratch/SHA256SUMS" "$dir/SHA256SUMS"
ssh-keygen -Y sign -f "$key" -n abla-release "$dir/SHA256SUMS" >/dev/null
"$here/verify-release.sh" "$dir"
