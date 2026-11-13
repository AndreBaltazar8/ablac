#!/usr/bin/env bash
# abla/crypto/rsapss: Wycheproof's RSASSA-PSS verification vectors (tests/vectors/crypto/wycheproof, JSON as
# published: 2048, 3072 and 4096-bit keys, SHA-256 and SHA-512, salt lengths 32 and 0), and signing and verifying
# against Node's RSA-PSS (OpenSSL's) and an EMSA-PSS written in JavaScript: SHA-256, -384 and -512, salt lengths 0, the
# hash's and 7, keys of 2048, 2049 (the encoded message a byte shorter than the signature) and 3072 bits, a given salt
# byte for byte, refusals of a changed signature, message and salt length, of a key under 2048 bits and of SHA-224.
set -uo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=$project_root/build/crypto-pss
rm -rf "$out"
mkdir -p "$out"
cd "$project_root"
cases=tests/cases/crypto-pss

status=0
fail() { echo "FAIL $*"; status=1; }

pids=()
programs=(vectors tool)
for program in "${programs[@]}"; do
    "$compiler" build "$cases/$program.ab" -o "$out/$program" --no-cache > "$out/$program.build.log" 2>&1 &
    pids+=("$!")
done
for index in "${!programs[@]}"; do
    wait "${pids[$index]}" || { cat "$out/${programs[$index]}.build.log"; exit 2; }
done

if "$out/vectors" tests/vectors/crypto > "$out/vectors.log" 2>&1; then
    echo "ok   wycheproof rsa-pss: $(grep -v failures "$out/vectors.log" | awk '{ n += $2 } END { print n " tests" }')"
else
    fail vectors; tail -20 "$out/vectors.log"
fi

if node "$cases/peer.mjs" "$out/tool" > "$out/peer.log" 2>&1; then
    echo "ok   $(cat "$out/peer.log")"
else
    fail "peer"; tail -5 "$out/peer.log"
fi

[[ $status -eq 0 ]] && echo "crypto-pss: ok" || echo "crypto-pss: FAILED"
exit $status
