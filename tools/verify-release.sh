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
[[ -f $dir/SHA256SUMS ]] || fail "no SHA256SUMS in $dir"
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
fi
printf 'verify-release: signature good; %d file(s) match the signed checksums\n' "$count"
