#!/usr/bin/env bash
# abla/crypto/x25519: the RFC 7748 vectors, the iterated function (1 and 1,000 rounds; X25519_MILLION=1 adds the
# 1,000,000 of the RFC, about twenty minutes), the refusals, and random scalars and points against the openssl CLI
# (X25519_ROUNDS, default 60); release and --fast.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/x25519
rounds=${X25519_ROUNDS:-60}
rm -rf "$out"
mkdir -p "$out"
random_hex() { head -c "$1" /dev/urandom | od -An -vtx1 | tr -d ' \n'; }
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/x25519/main.ab -o "$out/main.$mode" "${flags[@]}"
    extra=()
    [[ ${X25519_MILLION:-0} == 1 ]] && extra=(million)
    result=$(ABLA_MAX_SECONDS=3000 "$root/tools/run-limited.sh" "$out/main.$mode" "${extra[@]}") || { echo "x25519 ($mode): $result" >&2; exit 1; }
    [[ $result == 'x25519 ok' ]] || { echo "x25519 ($mode): $result" >&2; exit 1; }
done
"$compiler" build tests/cases/x25519/tool.ab -o "$out/tool" --no-cache
if command -v openssl > /dev/null && openssl genpkey -algorithm X25519 -out "$out/probe.pem" 2> /dev/null; then
    for ((round = 0; round < rounds; round++)); do
        scalar=$(random_hex 32)
        point=$(random_hex 32)
        # A raw key as DER: the PKCS#8 and SubjectPublicKeyInfo prefixes of X25519 (RFC 8410).
        printf "$(printf '302e020100300506032b656e04220420%s' "$scalar" | sed 's/\(..\)/\\x\1/g')" > "$out/private.der"
        printf "$(printf '302a300506032b656e032100%s' "$point" | sed 's/\(..\)/\\x\1/g')" > "$out/public.der"
        expected=$(openssl pkeyutl -derive -keyform DER -inkey "$out/private.der" -peerform DER -peerkey "$out/public.der" 2> /dev/null |
            od -An -vtx1 | tr -d ' \n') || expected=
        actual=$("$out/tool" "$scalar" "$point")
        if [[ -n $expected ]]; then
            [[ $actual == "$expected" ]] || { echo "x25519: scalar $scalar point $point: $actual != openssl's $expected" >&2; exit 1; }
        fi
    done
    echo "x25519: $rounds random products equal openssl's"
else
    echo 'x25519: no openssl with X25519; the random comparison is skipped'
fi
echo 'x25519 ok'
