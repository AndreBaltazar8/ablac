#!/usr/bin/env bash
# Interop, limits, corruption and authenticated-corruption probes of the encrypted
# RSA key and PKCS#12 readers, driven by cases.txt. The corrupted inputs are the
# committed files in tests/vectors/crypto/encrypted-rsa/corrupt (see its MANIFEST,
# verified here); only fixture secrets are used.
# Usage: check.sh TOOL
set -euo pipefail
tool=$1
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/../../.." && pwd)
vectors=$root/tests/vectors/crypto
"$root/tools/verify-fixture-manifest.sh" "$vectors/encrypted-rsa/corrupt"
# A hung reader must not stall the suite; macOS has no timeout and runs unguarded.
guard=()
if command -v timeout >/dev/null 2>&1; then guard=(timeout 30); fi

# The modulus of the fixture key, hashed by openssl: what the tool must print.
modulus=$(openssl rsa -in "$vectors/rsa-implicit-key.pem" -modulus -noout | sed 's/^Modulus=//')
[[ ${#modulus} -ge 512 ]]
escaped=$(printf '%s' "$modulus" | sed 's/../\\x&/g')
expected=$(printf '%b' "$escaped" | openssl dgst -sha256 | sed 's/^.*= //')
[[ ${#expected} == 64 ]]

checks=0
while IFS='|' read -r file password mode iterations work size bags depth want; do
    case $file in ''|'#'*) continue ;; esac
    path=$vectors/$file
    [[ -f $path ]] || { echo "encrypted RSA: missing $file" >&2; exit 1; }
    status=0
    output=$(${guard[@]+"${guard[@]}"} "$tool" "$path" "$password" "$mode" "$iterations" "$work" "$size" "$bags" "$depth" 2>&1) || status=$?
    checks=$((checks + 1))
    if [[ $want == OK ]]; then
        [[ $status == 0 && $output == "$expected" ]] ||
            { echo "encrypted RSA: $file ($password, $mode): wanted the key, got status $status: $output" >&2; exit 1; }
    else
        [[ $status == 1 ]] || { echo "encrypted RSA: $file: wanted error '$want', exit status $status: $output" >&2; exit 1; }
        if [[ $want == 'wrong password or corrupt key' ]]; then
            [[ $output == "$want" ]] || { echo "encrypted RSA: $file: wanted exactly '$want', got: $output" >&2; exit 1; }
        else
            [[ $output == *"$want"* ]] || { echo "encrypted RSA: $file: wanted '$want' in: $output" >&2; exit 1; }
        fi
    fi
done < "$here/cases.txt"
echo "encrypted RSA and PKCS#12: $checks interop/MAC/limits/corruption checks passed"
