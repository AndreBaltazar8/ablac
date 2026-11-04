#!/usr/bin/env bash
# abla/crypto/aes and abla/crypto/rsa: the vectors of tools/test-crypto.sh (NIST CAVP, Wycheproof) on the
# hardware and software paths, on this CPU and on one with no AES (qemu64); refusals; random inputs against
# abla/crypto/hosted and the openssl CLI; known answers run on AArch64 under qemu and Wasm under Node, and
# compiled for Xtensa; and that neither links OpenSSL. What's read of the code is in tools/test-ct.sh.
# CRYPTO_ROUNDS sets the random rounds (default 30). Keys are generated here and never printed.
set -uo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
out=$project_root/build/crypto-pure
rounds=${CRYPTO_ROUNDS:-30}
rm -rf "$out"
mkdir -p "$out/keys" "$out/work"
chmod 700 "$out/keys"
cd "$project_root"
cases=tests/cases/crypto-pure

status=0
fail() { echo "FAIL $*"; status=1; }
hex() { od -An -vtx1 "$1" | tr -d ' \n'; }
random_hex() { head -c "$1" /dev/urandom | od -An -vtx1 | tr -d ' \n'; }

# (At once: each writes only its own files.)
pids=()
programs=(vectors edge tool against-hosted both kat-native)
for program in "${programs[@]}"; do
    "$compiler" build "$cases/$program.ab" -o "$out/$program" --no-cache \
        > "$out/$program.build.log" 2>&1 &
    pids+=("$!")
done
for index in "${!programs[@]}"; do
    wait "${pids[$index]}" || { cat "$out/${programs[$index]}.build.log"; exit 2; }
done
tool=$out/tool

# --- Vectors, on both paths, and on a CPU with neither instruction ------------------------
if "$out/vectors" tests/vectors/crypto > "$out/vectors.log" 2>&1; then
    echo "ok   vectors: $(grep -v failures "$out/vectors.log" | tr '\n' ' ')"
else
    fail vectors; tail -20 "$out/vectors.log"
fi
if qemu-x86_64 -cpu qemu64 "$out/vectors" tests/vectors/crypto > "$out/vectors-qemu.log" 2>&1; then
    grep -q '^hardware' "$out/vectors-qemu.log" && fail "qemu64 took hardware rounds"
    echo "ok   vectors under qemu64, no AES or CLMUL: $(grep -v failures "$out/vectors-qemu.log" | head -1)"
else
    fail "vectors under qemu64"; tail -20 "$out/vectors-qemu.log"
fi

# --- Keys, refusals ------------------------------------------------------------------------
keys=$out/keys
{
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:1024 -out "$keys/k1024.pem"
    openssl rsa -in "$keys/k1024.pem" -traditional -out "$keys/k1024-traditional.pem"
    openssl pkcs8 -topk8 -nocrypt -in "$keys/k1024.pem" -outform DER -out "$keys/k1024.der"
    openssl rsa -in "$keys/k1024.pem" -traditional -outform DER -out "$keys/k1024-traditional.der"
    openssl pkcs8 -topk8 -in "$keys/k1024.pem" -passout 'pass:secret words' -out "$keys/k1024-encrypted.pem"
    openssl pkey -in "$keys/k1024.pem" -pubout -out "$keys/spki.pem"
    openssl pkey -in "$keys/k1024.pem" -pubout -outform DER -out "$keys/spki.der"
    openssl rsa -in "$keys/k1024.pem" -RSAPublicKey_out -out "$keys/rsapublic.pem"
    openssl req -x509 -new -key "$keys/k1024.pem" -days 2 -subj /CN=test -sha256 -out "$keys/certificate.pem"
    openssl x509 -in "$keys/certificate.pem" -outform DER -out "$keys/certificate.der"
    openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$keys/k2048.pem"
    openssl pkey -in "$keys/k2048.pem" -pubout -out "$keys/k2048-spki.pem"
    openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$keys/ec.pem"
    openssl pkey -in "$keys/ec.pem" -pubout -out "$keys/ec-spki.pem"
    openssl genpkey -algorithm RSA-PSS -pkeyopt rsa_keygen_bits:2048 -out "$keys/pss.pem"
} > "$out/keys.log" 2>&1 || { fail "generating keys"; sed 's/^/     /' "$out/keys.log"; exit 1; }

if timeout 300 "$out/edge" "$keys" > "$out/edge.log" 2>&1 < /dev/null; then
    echo "ok   refusals"
else
    fail "edge (exit $?)"; tail -20 "$out/edge.log"
fi
if timeout 300 "$out/against-hosted" "$keys" "$rounds" > "$out/against-hosted.log" 2>&1 < /dev/null; then
    echo "ok   against abla/crypto/hosted: $rounds rounds"
else
    fail "against hosted (exit $?)"; tail -20 "$out/against-hosted.log"
fi

if timeout 60 "$out/both" "$keys/k2048.pem" > "$out/both.log" 2>&1 < /dev/null; then
    echo "ok   one program with both RSAs, no aliases"
else
    fail "both (exit $?)"; tail -20 "$out/both.log"
fi

# --- Random inputs against the openssl CLI, on both paths ------------------------------------
work=$out/work
compare() { [[ $2 == "$3" ]] || fail "$1: ours ${2:0:64} theirs ${3:0:64}"; }
sizes=(0 1 15 16 17 31 32 33 64 100 1000)
for ((round = 0; round < rounds; round++)); do
    size=${sizes[$((round % ${#sizes[@]}))]}
    path=hardware; ((round % 2)) && path=software
    head -c "$size" /dev/urandom > "$work/message"
    for bits in 128 192 256; do
        key=$(random_hex $((bits / 8)))
        iv=$(random_hex 16)
        openssl enc -aes-"$bits"-ecb -K "$key" -in "$work/message" -out "$work/theirs" 2>/dev/null
        compare "ecb-encrypt $bits" "$("$tool" ecb-encrypt "$path" "$key" "$work/message")" "$(hex "$work/theirs")"
        compare "ecb-decrypt $bits" "$("$tool" ecb-decrypt "$path" "$key" "$work/theirs")" "$(hex "$work/message")"
        openssl enc -aes-"$bits"-cbc -K "$key" -iv "$iv" -in "$work/message" -out "$work/theirs" 2>/dev/null
        compare "cbc-encrypt $bits" "$("$tool" cbc-encrypt "$path" "$key" "$iv" "$work/message")" "$(hex "$work/theirs")"
        compare "cbc-decrypt $bits" "$("$tool" cbc-decrypt "$path" "$key" "$iv" "$work/theirs")" "$(hex "$work/message")"
    done
    for spec in "sha1 k1024.pem spki.pem" "sha256 k2048.pem k2048-spki.pem"; do
        read -r hash private public <<< "$spec"
        openssl dgst -"$hash" -sign "$keys/$private" -out "$work/signature" "$work/message"
        compare "sign-$hash" "$("$tool" "sign-$hash" - "$keys/$private" "$work/message")" "$(hex "$work/signature")"
        compare "verify-$hash" "$("$tool" "verify-$hash" - "$keys/$public" "$work/message" "$work/signature")" yes
    done
    head -c $((RANDOM % 64)) /dev/urandom > "$work/secret"
    for spec in "pkcs1 rsa_padding_mode:pkcs1 rsa_padding_mode:pkcs1" \
        "oaep-sha1 rsa_padding_mode:oaep rsa_oaep_md:sha1" "oaep-sha256 rsa_padding_mode:oaep rsa_oaep_md:sha256"; do
        read -r padding first second <<< "$spec"
        options=(-pkeyopt "$first" -pkeyopt "$second")
        [[ $padding != oaep-sha256 ]] || options+=(-pkeyopt rsa_mgf1_md:sha256)
        "$tool" "encrypt-$padding" - "$keys/k2048-spki.pem" "$work/secret" > "$work/ours.hex"
        python3 -Ic "import sys;open(sys.argv[2],'wb').write(bytes.fromhex(open(sys.argv[1]).read()))" \
            "$work/ours.hex" "$work/ours"
        openssl pkeyutl -decrypt -inkey "$keys/k2048.pem" "${options[@]}" -in "$work/ours" -out "$work/back" 2>/dev/null ||
            fail "openssl refused our $padding"
        compare "encrypt-$padding" "$(hex "$work/back")" "$(hex "$work/secret")"
        openssl pkeyutl -encrypt -pubin -inkey "$keys/k2048-spki.pem" "${options[@]}" -in "$work/secret" -out "$work/theirs" 2>/dev/null || fail "openssl encryption $padding"
        compare "decrypt-$padding" "$("$tool" "decrypt-$padding" - "$keys/k2048.pem" "$work/theirs")" "$(hex "$work/secret")"
    done
done
[[ $status -ne 0 ]] || echo "ok   openssl cross-check: $rounds rounds"

# --- Known answers elsewhere ---------------------------------------------------------------
"$out/kat-native" || fail "known answers native: $?"
"$compiler" build "$cases/wasm-build.ab" -o "$out/wasm-driver" --no-cache > "$out/wasm.log" 2>&1 || { cat "$out/wasm.log"; fail "wasm build"; }
"$out/wasm-driver" && node "$cases/run.mjs" "$out/crypto.wasm" && echo "ok   wasm under node: known answers, software" || fail "wasm"
"$compiler" build "$cases/aarch64-build.ab" -o "$out/aarch64-driver" --no-cache > "$out/aarch64.log" 2>&1 || { cat "$out/aarch64.log"; fail "aarch64 build"; }
llvm-mc -triple aarch64-linux-gnu -filetype=obj tests/cases/simd/aarch64-start.s -o "$out/aarch64-start.o"
ld.lld -static --no-pie -z notext "$out/aarch64.o" "$out/aarch64-start.o" -o "$out/aarch64"
llvm-objdump -d "$out/aarch64" > "$out/aarch64.s"
grep -q aese "$out/aarch64.s" || fail "no AESE in the AArch64 program"
if qemu-aarch64 -cpu max "$out/aarch64"; then echo "ok   aarch64 under qemu: known answers, hardware and software"; else fail "aarch64: check $?"; fi
tools_directory="$out/xtensa-tools"
mkdir -p "$tools_directory"
real_llc=$(command -v llc)
cat > "$tools_directory/llc" <<EOF
#!/usr/bin/env bash
arguments=()
for argument in "\$@"; do
    [[ \$argument == -relocation-model=pic ]] && argument=-relocation-model=static
    arguments+=("\$argument")
done
exec "$real_llc" -mcpu=esp32 "\${arguments[@]}"
EOF
chmod +x "$tools_directory/llc"
if PATH="$tools_directory:$PATH" "$compiler" build "$cases/object.ab" -o "$out/xtensa.o" --no-cache \
    --target-triple xtensa-esp-unknown-elf --object-format elf --emit object > "$out/xtensa.log" 2>&1; then
    echo "ok   xtensa: compiled, not run"
else
    cat "$out/xtensa.log"; fail "xtensa build"
fi

# --- What links what --------------------------------------------------------------------------
if readelf -d "$tool" 2>/dev/null | grep -q -E 'libcrypto|libssl'; then fail "abla/crypto/rsa links OpenSSL"; else echo "ok   no OpenSSL linked"; fi
key_text=$(sed -n 2p "$keys/k1024.pem")
if grep -l -F "$key_text" "$out"/*.log > /dev/null 2>&1; then fail "a log holds key material"; fi

[[ $status -eq 0 ]] && echo "crypto-pure: ok" || echo "crypto-pure: FAILED"
exit "$status"
