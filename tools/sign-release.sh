#!/usr/bin/env bash
# Signs a release's assets: writes DIR/SHA256SUMS (every file in DIR, sorted, as `<sha256>  <name>`) and signs it with
# ssh-keygen -Y sign (namespace abla-release) into DIR/SHA256SUMS.sig, then verifies the result against
# release-signing.pub (tools/verify-release.sh) so a wrong key never ships.
#
#   tools/sign-release.sh DIR KEYFILE
#
# KEYFILE is the private key (the workflow writes it from the ABLA_RELEASE_SIGNING_KEY secret and deletes it after).
set -euo pipefail
here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
dir=${1:?usage: sign-release.sh DIR KEYFILE}
key=${2:?usage: sign-release.sh DIR KEYFILE}
[[ -d $dir && -f $key ]] || { echo "sign-release: need a directory and a key file" >&2; exit 2; }
rm -f "$dir/SHA256SUMS" "$dir/SHA256SUMS.sig"
(
    cd "$dir"
    find . -type f | LC_ALL=C sort | sed 's|^\./||' | while IFS= read -r name; do
        case $name in */*) echo "sign-release: nested file $name" >&2; exit 1 ;; esac
        if command -v sha256sum >/dev/null 2>&1; then sha256sum "$name"; else shasum -a 256 "$name"; fi
    done > SHA256SUMS.tmp
    mv SHA256SUMS.tmp SHA256SUMS
)
ssh-keygen -Y sign -f "$key" -n abla-release "$dir/SHA256SUMS" >/dev/null
"$here/verify-release.sh" "$dir"
