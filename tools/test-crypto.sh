#!/usr/bin/env bash
# abla/crypto and abla/crypto/hosted: NIST CAVP and Wycheproof vectors
# (tests/vectors/crypto), refusals on keys generated here, random inputs compared
# with the openssl CLI both ways, mutual TLS against `openssl s_server`, and that only
# the hosted module links OpenSSL. CRYPTO_ROUNDS sets the random rounds (default 40).
# The ordinary 2048-bit key is generated for this run; weak and PSS keys are public test fixtures.
set -uo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=${CRYPTO_TEST_OUTPUT:-$project_root/build/crypto}
rounds=${CRYPTO_ROUNDS:-40}
rm -rf "$out"
mkdir -p "$out/keys" "$out/work"
chmod 700 "$out/keys"
cd "$project_root"

status=0
fail() { echo "FAIL $*"; status=1; }
hex() { od -An -vtx1 "$1" | tr -d ' \n'; }
random_hex() { head -c "$1" /dev/urandom | od -An -vtx1 | tr -d ' \n'; }

server_pid=
cleanup() { [[ -z $server_pid ]] || kill "$server_pid" 2>/dev/null; }
trap cleanup EXIT

for program in vectors edge tool; do
    "$compiler" build "tests/cases/crypto/$program.ab" -o "$out/$program" --fast --no-cache \
        > "$out/$program.build.log" 2>&1 || { cat "$out/$program.build.log"; exit 2; }
done
tool=$out/tool
# This helper generates interop keys; the dedicated keygen test still covers --fast.
ABLA_TEST_FAST_BUILDS=0 "$compiler" build tests/cases/rsa-keygen/generate.ab -o "$out/generate-rsa" --o1 --no-cache \
    > "$out/generate-rsa.build.log" 2>&1 || { cat "$out/generate-rsa.build.log"; exit 2; }

# --- Vectors ---------------------------------------------------------------------
if "$out/vectors" tests/vectors/crypto > "$out/vectors.log" 2>&1; then
    echo "ok   vectors: $(grep -v failures "$out/vectors.log" | tr '\n' ' ')"
else
    fail vectors; cat "$out/vectors.log"
fi

# --- Keys, in every form ---------------------------------------------------------
keys=$out/keys
make_keys() {
    cp tests/vectors/crypto/test-keys/legacy-rsa-1024.pem "$keys/k1024.pem"
    openssl rsa -in "$keys/k1024.pem" -traditional -out "$keys/k1024-traditional.pem"
    openssl pkcs8 -topk8 -nocrypt -in "$keys/k1024.pem" -outform DER -out "$keys/k1024.der"
    openssl rsa -in "$keys/k1024.pem" -traditional -outform DER -out "$keys/k1024-traditional.der"
    openssl pkcs8 -topk8 -in "$keys/k1024.pem" -passout 'pass:secret words' -out "$keys/k1024-encrypted.pem"
    openssl pkey -in "$keys/k1024.pem" -pubout -out "$keys/spki.pem"
    openssl pkey -in "$keys/k1024.pem" -pubout -outform DER -out "$keys/spki.der"
    openssl rsa -in "$keys/k1024.pem" -RSAPublicKey_out -out "$keys/rsapublic.pem"
    openssl req -x509 -new -key "$keys/k1024.pem" -days 2 -subj /CN=test -sha256 -out "$keys/certificate.pem"
    openssl x509 -in "$keys/certificate.pem" -outform DER -out "$keys/certificate.der"
    openssl pkcs12 -export -in "$keys/certificate.pem" -inkey "$keys/k1024.pem" -passout pass:pw -out "$keys/k1024.p12"
    openssl pkcs12 -export -legacy -in "$keys/certificate.pem" -inkey "$keys/k1024.pem" -passout pass:pw -out "$keys/k1024-legacy.p12"
    "$out/generate-rsa" "$keys/k2048.pem" || return 1
    openssl pkey -in "$keys/k2048.pem" -pubout -out "$keys/k2048-spki.pem"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$keys/ec.pem"
    openssl pkey -in "$keys/ec.pem" -pubout -out "$keys/ec-spki.pem"
    cp tests/vectors/crypto/test-keys/rsa-pss-2048.pem "$keys/pss.pem"
    cp tests/vectors/crypto/test-keys/legacy-rsa-768.pem "$keys/k768.pem"
}
make_keys > "$out/keys.log" 2>&1 || { fail "generating keys"; sed 's/^/     /' "$out/keys.log"; exit 1; }

# --- Refusals --------------------------------------------------------------------
if timeout 120 "$out/edge" "$keys" > "$out/edge.log" 2>&1 < /dev/null; then
    echo "ok   edge: $(grep -c '^note' "$out/edge.log") note(s): $(grep '^note' "$out/edge.log")"
else
    fail "edge (exit $?)"; cat "$out/edge.log"
fi

# --- Random inputs against the openssl CLI -----------------------------------------
work=$out/work
compare() { # label, ours, theirs
    [[ $2 == "$3" ]] || fail "$1: ours ${2:0:64} theirs ${3:0:64}"
}
sizes=(0 1 15 16 17 31 32 33 55 56 63 64 65 111 112 119 120 127 128 129 1000 5000)
for ((round = 0; round < rounds; round++)); do
    size=${sizes[$((round % ${#sizes[@]}))]}
    head -c "$size" /dev/urandom > "$work/message"
    for hash in sha1 sha256 sha384 sha512; do
        compare "$hash $size" "$("$tool" "$hash" "$work/message")" \
            "$(openssl dgst -"$hash" -r "$work/message" | cut -d' ' -f1)"
        key=$(random_hex $((RANDOM % 200 + 1)))
        compare "hmac-$hash" "$("$tool" "hmac-$hash" "$key" "$work/message")" \
            "$(openssl dgst -"$hash" -r -mac HMAC -macopt "hexkey:$key" "$work/message" | cut -d' ' -f1)"
    done
    for bits in 128 192 256; do
        key=$(random_hex $((bits / 8)))
        iv=$(random_hex 16)
        openssl enc -aes-"$bits"-ecb -K "$key" -in "$work/message" -out "$work/theirs" 2>/dev/null
        compare "ecb-encrypt $bits" "$("$tool" ecb-encrypt "$key" "$work/message")" "$(hex "$work/theirs")"
        compare "ecb-decrypt $bits" "$("$tool" ecb-decrypt "$key" "$work/theirs")" "$(hex "$work/message")"
        openssl enc -aes-"$bits"-cbc -K "$key" -iv "$iv" -in "$work/message" -out "$work/theirs" 2>/dev/null
        compare "cbc-encrypt $bits" "$("$tool" cbc-encrypt "$key" "$iv" "$work/message")" "$(hex "$work/theirs")"
        compare "cbc-decrypt $bits" "$("$tool" cbc-decrypt "$key" "$iv" "$work/theirs")" "$(hex "$work/message")"
    done
    # A deterministic signature matches byte for byte; both verify the other's.
    for spec in "1024 sha1 k1024.pem spki.pem" "2048 sha256 k2048.pem k2048-spki.pem"; do
        read -r _ hash private public <<< "$spec"
        openssl dgst -"$hash" -sign "$keys/$private" -out "$work/signature" "$work/message"
        compare "sign-$hash" "$("$tool" "sign-$hash" "$keys/$private" "$work/message")" "$(hex "$work/signature")"
        compare "verify-$hash" "$("$tool" "verify-$hash" "$keys/$public" "$work/message" "$work/signature")" yes
    done
    # Encryption is randomized, so each side decrypts the other's.
    head -c $((RANDOM % 64)) /dev/urandom > "$work/secret"
    for spec in \
        "pkcs1 rsa_padding_mode:pkcs1 rsa_padding_mode:pkcs1" \
        "oaep-sha1 rsa_padding_mode:oaep rsa_oaep_md:sha1" \
        "oaep-sha256 rsa_padding_mode:oaep rsa_oaep_md:sha256"; do
        read -r padding first second <<< "$spec"
        options=(-pkeyopt "$first" -pkeyopt "$second")
        [[ $padding != oaep-sha256 ]] || options+=(-pkeyopt rsa_mgf1_md:sha256)
        openssl pkeyutl -encrypt -pubin -inkey "$keys/k2048-spki.pem" "${options[@]}" \
            -in "$work/secret" -out "$work/theirs" 2>/dev/null
        compare "decrypt-$padding" "$("$tool" "decrypt-$padding" "$keys/k2048.pem" "$work/theirs")" "$(hex "$work/secret")"
        "$tool" "encrypt-$padding" "$keys/k2048-spki.pem" "$work/secret" > "$work/ours.hex"
        python3 -Ic "import sys;open(sys.argv[2],'wb').write(bytes.fromhex(open(sys.argv[1]).read()))" \
            "$work/ours.hex" "$work/ours"
        openssl pkeyutl -decrypt -inkey "$keys/k2048.pem" "${options[@]}" -in "$work/ours" -out "$work/back" 2>/dev/null ||
            fail "openssl refused our $padding"
        compare "encrypt-$padding" "$(hex "$work/back")" "$(hex "$work/secret")"
    done
done
[[ $status -ne 0 ]] || echo "ok   openssl cross-check: $rounds rounds"

# --- Mutual TLS against openssl s_server --------------------------------------------
tls=$out/keys/tls
mkdir -p "$tls"
make_identity() { # name, signing CA
    cp "tests/vectors/crypto/test-keys/tls-$1.pem" "$tls/$1.key"
    openssl req -new -key "$tls/$1.key" -subj "/CN=$1" -out "$tls/$1.csr"
    openssl x509 -req -in "$tls/$1.csr" -CA "$tls/$2.pem" -CAkey "$tls/$2.key" -CAcreateserial -days 2 \
        -sha256 -extfile <(printf 'subjectAltName=DNS:localhost') -out "$tls/$1.pem"
}
{
    cp tests/vectors/crypto/test-keys/tls-ca.pem "$tls/ca.key"
    cp tests/vectors/crypto/test-keys/tls-other.pem "$tls/other.key"
    openssl req -x509 -new -key "$tls/ca.key" -subj /CN=ca -days 2 -out "$tls/ca.pem"
    openssl req -x509 -new -key "$tls/other.key" -subj /CN=other -days 2 -out "$tls/other.pem"
    make_identity server ca
    make_identity client ca
    make_identity stranger other
    openssl pkcs12 -export -in "$tls/client.pem" -inkey "$tls/client.key" -certfile "$tls/ca.pem" -passout pass:pw -out "$tls/client.p12"
    openssl pkcs8 -topk8 -in "$tls/client.key" -passout pass:words -out "$tls/client-encrypted.key"
} > "$out/tls-keys.log" 2>&1 || { fail "generating TLS keys"; sed 's/^/     /' "$out/tls-keys.log"; }

start_server() { # extra s_server arguments
    openssl s_server -accept 0 -cert "$tls/server.pem" -key "$tls/server.key" -CAfile "$tls/ca.pem" \
        -Verify 1 -verify_return_error -www "$@" > "$out/s_server.log" 2>&1 < /dev/null &
    server_pid=$!
    port=
    for _ in $(seq 1 100); do
        port=$(sed -n 's/^ACCEPT .*:\([0-9][0-9]*\)$/\1/p' "$out/s_server.log" | head -1)
        [[ -z $port ]] || return 0
        sleep 0.1
    done
    fail "s_server did not start"
    sed 's/^/     /' "$out/s_server.log"
}
stop_server() { kill "$server_pid" 2>/dev/null; wait "$server_pid" 2>/dev/null; server_pid=; }

expect_accepted() { # label, command...
    local label=$1; shift
    local reply; reply=$(timeout 20 "$@" 2>&1)
    if [[ $? -eq 0 && $reply == *200* ]]; then echo "ok   mtls $label"; else fail "mtls $label: $reply"; fi
}
expect_refused() {
    local label=$1; shift
    local reply; reply=$(timeout 20 "$@" 2>&1)
    if [[ $? -eq 3 ]]; then echo "ok   mtls $label refused"; else fail "mtls $label should fail: $reply"; fi
}
for protocol in -tls1_3 -tls1_2; do
    start_server "$protocol"
    expect_accepted "$protocol pem" "$tool" mtls-pem "$port" "$tls/ca.pem" "$tls/client.pem" "$tls/client.key"
    expect_accepted "$protocol encrypted key" "$tool" mtls-pem "$port" "$tls/ca.pem" "$tls/client.pem" "$tls/client-encrypted.key" words
    expect_accepted "$protocol pkcs12" "$tool" mtls-p12 "$port" "$tls/ca.pem" "$tls/client.p12" pw
    expect_accepted "$protocol https pem" "$tool" https-pem "$port" "$tls/ca.pem" "$tls/client.pem" "$tls/client.key"
    expect_accepted "$protocol https pkcs12" "$tool" https-p12 "$port" "$tls/ca.pem" "$tls/client.p12" pw
    expect_refused "$protocol no certificate" "$tool" mtls-none "$port" "$tls/ca.pem"
    expect_refused "$protocol other CA's certificate" "$tool" mtls-pem "$port" "$tls/ca.pem" "$tls/stranger.pem" "$tls/stranger.key"
    expect_refused "$protocol wrong key" "$tool" mtls-pem "$port" "$tls/ca.pem" "$tls/client.pem" "$tls/stranger.key"
    expect_refused "$protocol wrong passphrase" "$tool" mtls-pem "$port" "$tls/ca.pem" "$tls/client.pem" "$tls/client-encrypted.key" nope
    expect_refused "$protocol wrong pkcs12 password" "$tool" mtls-p12 "$port" "$tls/ca.pem" "$tls/client.p12" nope
    expect_refused "$protocol untrusted server" "$tool" mtls-pem "$port" "$tls/other.pem" "$tls/client.pem" "$tls/client.key"
    stop_server
done

# --- What links what, and what's never printed ---------------------------------------
cat > "$out/portable.ab" <<'PROGRAM'
import "abla/crypto"
fun main: int = if (sha512("abc").size == 64) 0 else 1
PROGRAM
"$compiler" build "$out/portable.ab" -o "$out/portable" --fast --no-cache > "$out/portable.log" 2>&1 || fail "portable build"
if readelf -d "$out/portable" 2>/dev/null | grep -q -E 'libcrypto|libssl'; then fail "abla/crypto alone links OpenSSL"; else echo "ok   abla/crypto alone doesn't link OpenSSL"; fi
readelf -d "$tool" | grep -q libcrypto && echo "ok   abla/crypto/hosted links OpenSSL" || fail "abla/crypto/hosted doesn't link OpenSSL"

key_text=$(sed -n 2p "$keys/k1024.pem")
if grep -l -F "$key_text" "$out"/*.log > /dev/null 2>&1; then fail "a log holds key material"; else echo "ok   no key material in the logs"; fi

[[ $status -eq 0 ]] && echo "crypto: ok" || echo "crypto: FAILED"
exit "$status"
