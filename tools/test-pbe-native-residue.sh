#!/usr/bin/env bash
# The decrypted private key of abla/crypto/pbe is not left in a native program's memory (the TODO "Secret residue"
# search, natively): tests/cases/pbe-native-residue opens the committed encrypted fixtures through abla/crypto/rsa
# (an encrypted PKCS#8 DER, a PKCS#12, an encrypted PEM with the password inline), drops what it opened, collects twice
# and scans its own readable and writable mappings for windows of the key's p, q, d, dp, dq and qinv and of the
# password; nothing may be left. The control, the unencrypted key's DER in a managed string nothing wipes, must be
# found. In release and --fast on x86-64, and on AArch64 under qemu-aarch64 (whose /proc/self/maps is the guest's).
# PBE_RESIDUE_EXPECT=leak inverts the verdict for the opened keys (a tree whose entries don't wipe yet, as a measurement).
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
out=build/pbe-native-residue
rm -rf "$out"
mkdir -p "$out"
[[ $(uname -s) == Linux ]] || { echo "pbe native residue: not Linux, skipped"; exit 0; }
command -v openssl > /dev/null || { echo "pbe native residue: no openssl, skipped"; exit 0; }

fixtures=tests/vectors/crypto/encrypted-rsa
hex() { od -An -v -tx1 | tr -d ' \n'; }
# The windows: "<kind> <hex>" lines, 16-byte windows of each number at every byte offset in both byte orders (kinds 0
# to 11), 8-byte windows of the password in ASCII (12) and UTF-16 (13). From the public fixture key, by openssl.
openssl rsa -in tests/vectors/crypto/rsa-implicit-key.pem -text -noout 2> /dev/null | awk '
    function emit(kind, h, size,    n, i) { n = length(h) / 2; for (i = 0; i + size <= n; i++) print kind, substr(h, 2 * i + 1, 2 * size) }
    function reversed(h,    r, i) { r = ""; for (i = length(h) - 1; i >= 1; i -= 2) r = r substr(h, i, 2); return r }
    function flush() {
        if (name == "") return
        sub(/^(00)+/, "", value)
        emit(base[name], value, 16); emit(base[name] + 1, reversed(value), 16)
        name = ""
    }
    BEGIN { base["prime1"] = 0; base["prime2"] = 2; base["privateExponent"] = 4; base["exponent1"] = 6
            base["exponent2"] = 8; base["coefficient"] = 10 }
    /^[a-zA-Z0-9]+:/ { flush(); field = $1; sub(/:$/, "", field); if (field in base) { name = field; value = "" }; next }
    /^ / { if (name != "") { line = $0; gsub(/[ :]/, "", line); value = value line } }
    END { flush() }' > "$out/needles.txt"
password=$(printf 'test-only-password' | hex)
utf16=$(printf '%s' "$password" | sed 's/../00&/g')
for kind in 12 13; do
    text=$([[ $kind == 12 ]] && echo "$password" || echo "$utf16")
    for ((i = 0; i + 16 <= ${#text}; i += 2)); do echo "$kind ${text:i:16}"; done
done >> "$out/needles.txt"
[[ $(wc -l < "$out/needles.txt") -gt 1500 ]] || { echo "pbe native residue: too few windows from openssl" >&2; exit 1; }
needles=$(awk '{ printf "%s,", $0 }' "$out/needles.txt")
sed -e "s|@P8HEX@|$(sed '1d;$d' "$fixtures/aes128-sha256.pem" | base64 -d | hex)|" \
    -e "s|@P12HEX@|$(hex < "$fixtures/modern.p12")|" \
    -e "s|@PEMHEX@|$(hex < "$fixtures/aes128-sha256.pem")|" \
    -e "s|@PLAINPEMHEX@|$(hex < tests/vectors/crypto/rsa-implicit-key.pem)|" \
    -e "s|@NEEDLES@|$needles|" tests/cases/pbe-native-residue/main.ab.in > "$out/main.ab"

failed=0
check() { # label runner...
    local label=$1; shift
    local mode output status
    for mode in pkcs8 pkcs12 pem control; do
        status=0
        output=$("$@" "$mode" 2>&1) || status=$?
        [[ $status == 0 ]] || { echo "pbe native residue: $label $mode exited $status: $output" >&2; failed=1; continue; }
        local key_left=$(grep -v 'password' <<<"$output" | grep -c '^left ' || true)
        if [[ $mode == control ]]; then
            [[ $key_left -gt 0 ]] || { echo "pbe native residue: $label control: the unwiped key was not found" >&2; failed=1; }
        elif [[ ${PBE_RESIDUE_EXPECT:-clean} == leak ]]; then
            echo "measure $label $mode: $(tr '\n' ';' <<<"$output")"
        elif [[ -n $output ]]; then
            echo "pbe native residue: $label $mode left: $(tr '\n' ';' <<<"$output")" >&2; failed=1
        fi
    done
    [[ $failed == 1 ]] || echo "ok   $label: nothing left after two collections; the control is found"
}
for mode in release fast; do
    flags=(); [[ $mode == release ]] || flags=(--fast)
    "$compiler" build "$out/main.ab" -o "$out/x86-$mode" --no-cache "${flags[@]}" > "$out/x86-$mode.log" 2>&1 ||
        { cat "$out/x86-$mode.log" >&2; echo "pbe native residue: x86-64 $mode did not build" >&2; exit 1; }
    check "x86-64 $mode" "$out/x86-$mode"
done
if command -v qemu-aarch64 > /dev/null; then
    for mode in release fast; do
        flags=(); [[ $mode == release ]] || flags=(--fast)
        "$compiler" build "$out/main.ab" --target aarch64-linux -o "$out/a64-$mode" --no-cache "${flags[@]}" \
            > "$out/a64-$mode.log" 2>&1 ||
            { cat "$out/a64-$mode.log" >&2; echo "pbe native residue: AArch64 $mode did not build" >&2; exit 1; }
        check "AArch64 $mode" timeout 600 qemu-aarch64 "$out/a64-$mode"
    done
else
    echo "pbe native residue: no qemu-aarch64, AArch64 not run"
fi
(( failed == 0 )) || exit 1
echo "pbe native residue: opened keys and passwords leave nothing in the process's memory; an unwiped key is found"
