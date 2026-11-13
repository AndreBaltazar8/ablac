#!/usr/bin/env bash
# abla/crypto/ed25519: RFC 8032 section 7.1's vectors, Wycheproof's 210 verification cases (tests/vectors/crypto/
# wycheproof-ed25519.json), the refusals, and random seeds and messages against the openssl CLI both ways
# (public keys, signatures, and each side verifying the other's); release and --fast. ED25519_ROUNDS sets the random rounds
# (default 40).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/ed25519
rounds=${ED25519_ROUNDS:-40}
rm -rf "$out"
mkdir -p "$out"
random_hex() { head -c "$1" /dev/urandom | od -An -vtx1 | tr -d ' \n'; }
unhex() { printf "$(printf '%s' "$1" | sed 's/\(..\)/\\x\1/g')"; }
for mode in release fast; do
    flags=(--no-cache)
    [[ $mode == fast ]] && flags+=(--fast)
    "$compiler" build tests/cases/ed25519/main.ab -o "$out/main.$mode" "${flags[@]}"
    result=$("$root/tools/run-limited.sh" "$out/main.$mode" tests/vectors/crypto) || { echo "ed25519 ($mode): $result" >&2; exit 1; }
    [[ $result == 'ed25519 ok (210 Wycheproof cases)' ]] || { echo "ed25519 ($mode): $result" >&2; exit 1; }
done
"$compiler" build tests/cases/ed25519/tool.ab -o "$out/tool" --no-cache
tool=$out/tool
if command -v openssl > /dev/null && openssl genpkey -algorithm ED25519 -out "$out/probe.pem" 2> /dev/null; then
    for ((round = 0; round < rounds; round++)); do
        seed=$(random_hex 32)
        length=$(( RANDOM % 300 ))
        message=$(random_hex "$length")
        # A raw seed as DER: the PKCS#8 prefix of Ed25519 (RFC 8410), and the SubjectPublicKeyInfo one for the key.
        unhex "302e020100300506032b657004220420$seed" > "$out/private.der"
        expected_public=$(openssl pkey -inform DER -in "$out/private.der" -pubout -outform DER | tail -c 32 | od -An -vtx1 | tr -d ' \n')
        actual_public=$("$tool" public "$seed")
        [[ $actual_public == "$expected_public" ]] || { echo "ed25519: seed $seed: public key $actual_public != openssl's $expected_public" >&2; exit 1; }
        unhex "$message" > "$out/message.bin"
        expected_signature=$(openssl pkeyutl -sign -rawin -keyform DER -inkey "$out/private.der" -in "$out/message.bin" | od -An -vtx1 | tr -d ' \n')
        actual_signature=$("$tool" sign "$seed" "$message")
        [[ $actual_signature == "$expected_signature" ]] || { echo "ed25519: seed $seed message $message: signature $actual_signature != openssl's $expected_signature" >&2; exit 1; }
        [[ $("$tool" verify "$actual_public" "$message" "$expected_signature") == true ]] || { echo "ed25519: ours did not verify openssl's signature" >&2; exit 1; }
        unhex "302a300506032b6570032100$actual_public" > "$out/public.der"
        unhex "$actual_signature" > "$out/signature.bin"
        openssl pkeyutl -verify -rawin -pubin -keyform DER -inkey "$out/public.der" -in "$out/message.bin" -sigfile "$out/signature.bin" > /dev/null ||
            { echo "ed25519: openssl did not verify our signature" >&2; exit 1; }
    done
    echo "ed25519: $rounds random seeds and messages equal openssl's, and verify both ways"
else
    echo 'ed25519: no openssl with Ed25519; the comparison is skipped'
fi
echo 'ed25519 ok'
