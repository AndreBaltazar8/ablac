#!/usr/bin/env bash
# Verifies a release's signed checksums, failing closed: the signature of SHA256SUMS against the project's public
# key (release-signing.pub, ssh-keygen -Y verify, namespace abla-release), then the assets against SHA256SUMS.
#
#   tools/verify-release.sh [--key FILE] DIR [NAME...]
#
# DIR holds SHA256SUMS, SHA256SUMS.sig and the assets. With NAMEs, each must be listed in SHA256SUMS and its file
# in DIR must match (a consumer that downloaded only what it needs). Without NAMEs, every file in DIR other than
# the two sums files must be listed and match. Anything else is a refusal: no signature, a signature that does not
# verify, a missing, extra or modified file. Needs bash, ssh-keygen, awk and sha256sum or shasum; no Python.
set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
key=$here/../release-signing.pub
case ${1:-} in --key) key=${2:?}; shift 2 ;; esac
dir=${1:-}
[[ -n $dir ]] || { sed -n '2,/^set -uo/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//' >&2; exit 2; }
shift
fail() { printf 'verify-release: REFUSED: %s\n' "$*" >&2; exit 1; }

[[ -f $key ]] || fail "no public key at $key"
[[ -f $dir/SHA256SUMS ]] || fail "no SHA256SUMS in $dir (download it and SHA256SUMS.sig with the assets; a draft has neither until its publish job signs it, and releases before $(cat "$here/first-signed-release" 2>/dev/null || echo the first signed one) are not signed)"
[[ -f $dir/SHA256SUMS.sig ]] || fail "no SHA256SUMS.sig in $dir"
command -v ssh-keygen >/dev/null 2>&1 || fail "ssh-keygen is needed to verify the signature"

work=$(mktemp -d "${TMPDIR:-/tmp}/verify-release.XXXXXX") || exit 1
trap 'rm -rf -- "$work"' EXIT
# allowed signers: principal, key type, key (the comment of the key file is dropped).
awk 'NR == 1 { print "ablac-release " $1 " " $2 }' "$key" > "$work/allowed"
ssh-keygen -Y verify -f "$work/allowed" -I ablac-release -n abla-release -s "$dir/SHA256SUMS.sig" \
    < "$dir/SHA256SUMS" > "$work/verify.log" 2>&1 || fail "the signature of SHA256SUMS does not verify ($(tr '\n' ' ' < "$work/verify.log"))"

sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | cut -d' ' -f1
    else shasum -a 256 "$1" | cut -d' ' -f1; fi
}
listed=$work/listed
# Each line is `<64 hex>  <name>`: anything else in a signed file is a refusal too.
awk '!($0 ~ /^[0-9a-f]{64}  [^\/ ][^\/]*$/) { bad = 1 } END { exit bad }' "$dir/SHA256SUMS" || fail "SHA256SUMS has a malformed line"
cp "$dir/SHA256SUMS" "$listed"

check() {
    local name=$1 want have
    want=$(awk -v n="$name" '$2 == n { print $1; exit }' "$listed")
    [[ -n $want ]] || fail "$name is not listed in the signed SHA256SUMS"
    [[ -f $dir/$name ]] || fail "$name is listed but missing from $dir"
    have=$(sha256 "$dir/$name")
    [[ $have == "$want" ]] || fail "$name does not match the signed checksum (got $have, signed $want)"
}

count=0
if (($#)); then
    for name in "$@"; do check "$name"; count=$((count + 1)); done
else
    while IFS= read -r path; do
        name=${path#"$dir"/}
        case $name in SHA256SUMS | SHA256SUMS.sig) continue ;; esac
        check "$name"; count=$((count + 1))
    done < <(find "$dir" -type f | LC_ALL=C sort)
    # A listed file that is not in DIR is a refusal too, except the scratch files v0.2.67 to v0.2.73 signed by mistake and
    # never published, each only with the hash that release signed: their own temporary list SHA256SUMS.tmp (empty in
    # v0.2.68-v0.2.73; in v0.2.67 a partial list, ab186c87...) and release-check's empty marker .release-check (v0.2.67).
    # No release since carries them.
    empty=e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    while read -r want name; do
        [[ -f $dir/$name ]] && continue
        [[ $name == SHA256SUMS.tmp && $want == "$empty" ]] && continue
        [[ $name == SHA256SUMS.tmp && $want == ab186c87ae549a4a732441f983e56f70b09770bc0260ef83db103d1914e7e9dd ]] && continue
        [[ $name == .release-check && $want == "$empty" ]] && continue
        fail "$name is listed in the signed SHA256SUMS but missing from $dir"
    done < "$listed"
fi
printf 'verify-release: signature good; %d file(s) match the signed checksums\n' "$count"
