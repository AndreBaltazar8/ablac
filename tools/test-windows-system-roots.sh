#!/usr/bin/env bash
# The Windows system trust store (the runtime's system call 4006: crypt32's ROOT store) under Wine, with certificates put into the prefix's
# registry stores: tests/cases/windows/system-roots.ab connects to its own TLS server with the system trust store and prints `trusted true|false`.
#   - no certificate in any store: not trusted;
#   - the server's certificate in ROOT: trusted;
#   - the same certificate also in Disallowed (what Windows distrusts): not trusted;
#   - in ROOT with an enhanced key usage property that lacks server authentication, or an empty one (a root an administrator disabled): not
#     trusted; with a property that names server authentication: trusted.
# Skipped (exit 0, a message) without Wine, lld-link or openssl. The prefix is the script's own, under build/.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
for tool in lld-link openssl sha1sum od; do
    command -v "$tool" > /dev/null || { echo "windows-system-roots: skipped ($tool is not installed)"; exit 0; }
done
out=$root/build/windows-system-roots
rm -rf "$out"
mkdir -p "$out"
export ABLA_WINE_PREFIX=$out/prefix
fail() { echo "windows-system-roots: $1" >&2; exit 1; }
wine() { "$root/tools/windows/wine-run.sh" "$@"; }
"$compiler" build tests/cases/windows/system-roots.ab --target x86_64-windows-hosted -o "$out/system-roots.exe" --fast --no-cache > "$out/build.log" 2>&1 ||
    { cat "$out/build.log" >&2; fail "did not build"; }
cd "$out"
status=0
wine "$out/system-roots.exe" writecert > /dev/null 2>&1 || status=$?
if [[ $status == 125 ]]; then echo "windows-system-roots: skipped (no Wine)"; exit 0; fi
[[ $status == 0 && -s system-roots-cert.pem ]] || fail "writecert failed ($status)"
openssl x509 -in system-roots-cert.pem -outform DER -out cert.der
thumbprint=$(sha1sum cert.der | cut -d' ' -f1 | tr a-f A-F)
le32() { printf '%02x%02x%02x%02x' $(($1 & 255)) $((($1 >> 8) & 255)) $((($1 >> 16) & 255)) $((($1 >> 24) & 255)); }
# A serialized certificate element: each property is its id, 1, its length and its bytes (CERT_CERT_PROP_ID 32 holds the certificate).
property() { printf '%s%s%s%s' "$(le32 "$1")" "$(le32 1)" "$(le32 $((${#2} / 2)))" "$2"; }
certificate=$(od -An -v -tx1 cert.der | tr -d " \n")
key() { printf 'HKCU\\Software\\Microsoft\\SystemCertificates\\%s\\Certificates\\%s' "$1" "$thumbprint"; }
add() { # add <store> <hex of the extra properties, or nothing>
    wine reg add "$(key "$1")" /v Blob /t REG_BINARY /d "$(property 32 "$certificate")${2:-}" /f > /dev/null 2>&1 || fail "reg add $1 failed"
}
remove() { wine reg delete "$(key "$1")" /f > /dev/null 2>&1 || true; }
run() { # run <name> <expected>
    local line
    line=$(wine "$out/system-roots.exe" 2>/dev/null | tr -d '\r' | grep '^trusted ' || true)
    [[ $line == "trusted $2" ]] || fail "$1: expected 'trusted $2', got '$line'"
    echo "ok   $1: $line"
}
serverAuth=300a06082b06010505070301
codeSigning=300a06082b06010505070303
run "no certificate in the stores" false
add ROOT
run "the certificate in ROOT" true
remove ROOT
add ROOT; add Disallowed
run "the certificate in ROOT and in Disallowed" false
remove ROOT; remove Disallowed
add ROOT "$(property 9 "$codeSigning")"
run "in ROOT with an enhanced key usage without server authentication" false
remove ROOT
add ROOT "$(property 9 "$serverAuth")"
run "in ROOT with an enhanced key usage naming server authentication" true
remove ROOT
add ROOT "$(property 9 3000)"
run "in ROOT with an empty enhanced key usage (every usage disabled)" false
remove ROOT
run "removed again" false
echo "windows-system-roots: the system roots are the ROOT store minus Disallowed and the roots disabled for server authentication"
