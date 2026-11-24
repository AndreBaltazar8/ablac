#!/usr/bin/env bash
# abla/tls/pure with revocation checking by OCSP stapling (tests/cases/tls-pure/ocsp.ab) against `openssl s_server -status_file`, in TLS 1.3 and TLS 1.2: a CA, a leaf, a revoked
# leaf and a must-staple leaf are made here with the responses `openssl ocsp` gives them, and each case starts a server. A good staple connects under every policy; a revoked one, one for
# another certificate and an expired one (the client's OCSP clock eight days on) are refused when revocation is on, and not looked at when it is off; no staple connects under the staple
# policy and is refused under the require policy and for a must-staple certificate. The second program (tests/cases/tls-pure/ocsp-default.ab) is the stock client with no revocation setting: it offers status_request and checks staples by default (good, none, revoked, wrong certificate,
# a response valid for more than ten days, must-staple), and a configuration with revocation 0 offers none; the server's log says what the ClientHello carried and which alert the client sent. Skipped, with a message, without openssl. Usage: tools/test-tls-ocsp.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
. "$root/tools/lib/openssl-server.sh"
command -v openssl > /dev/null || { echo "tls-ocsp: no openssl; skipped"; exit 0; }
out=build/tls-ocsp
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/tls-pure/ocsp.ab -o "$out/ocsp" --no-cache > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
"$compiler" build tests/cases/tls-pure/ocsp-default.ab -o "$out/ocsp-default" --no-cache > "$out/build-default.log" 2>&1 || { cat "$out/build-default.log" >&2; exit 1; }
cd "$out"
key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1.key" 2> /dev/null; }
for name in ca leaf leafrevoked leafmust; do key $name; done
openssl req -x509 -new -key ca.key -out ca.pem -subj '/CN=OCSP Test CA' -days 30 -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,digitalSignature' 2> /dev/null
issue() {
    local name=$1 serial=$2
    shift 2
    printf '%s\n' "subjectAltName=DNS:localhost" "extendedKeyUsage=serverAuth" "$@" > "$name.ext"
    openssl req -new -key "$name.key" -subj /CN=localhost -out "$name.csr" 2> /dev/null
    openssl x509 -req -in "$name.csr" -CA ca.pem -CAkey ca.key -set_serial "$serial" -days 20 -extfile "$name.ext" -out "$name.pem" 2> /dev/null
}
issue leaf 0x1001
issue leafmust 0x1002 'tlsfeature=status_request'
issue leafrevoked 0x1003
future=$(date -u -d '+10 days' +%y%m%d%H%M%SZ)
{
    printf 'V\t%s\t\t1001\tunknown\t/CN=leaf\n' "$future"
    printf 'V\t%s\t\t1002\tunknown\t/CN=must\n' "$future"
    printf 'R\t%s\t250101000000Z,keyCompromise\t1003\tunknown\t/CN=revoked\n' "$future"
} > index.txt
for name in leaf leafmust leafrevoked; do
    openssl ocsp -issuer ca.pem -cert "$name.pem" -reqout "$name.req" -no_nonce 2> /dev/null
    openssl ocsp -index index.txt -CA ca.pem -rsigner ca.pem -rkey ca.key -reqin "$name.req" -respout "$name.resp" -no_nonce -ndays 5 2> /dev/null
done
# A response good for eleven days: longer than the ten the client accepts (the Baseline Requirements' limit; a staple is judged for its freshness, the clock-driven expiry is the "expired staple" case above), and one good for exactly ten.
openssl ocsp -index index.txt -CA ca.pem -rsigner ca.pem -rkey ca.key -reqin leaf.req -respout leaflong.resp -no_nonce -ndays 11 2> /dev/null
openssl ocsp -index index.txt -CA ca.pem -rsigner ca.pem -rkey ca.key -reqin leaf.req -respout leafmax.resp -no_nonce -ndays 10 2> /dev/null
failed=0
# case NAME CERTIFICATE [STAPLE] -- EXPECTATION POLICY OFFSET
run_case() {
    local version=$1 label=$2 cert=$3 staple=$4 expect=$5 policy=$6 offset=$7
    local options=(-cert "$cert.pem" -key "$cert.key" -$version -www)
    [[ $staple == none ]] || options+=(-status_file "$staple.resp")
    openssl_server_start server.log '[::1]:0' "${options[@]}" || { echo "tls-ocsp: no server for $version $label" >&2; failed=1; return; }
    local result status=0
    result=$(timeout 30 ./ocsp "$openssl_server_port" ca.pem "$expect" "$policy" "$offset" 2>&1) || status=$?
    kill "$openssl_server_pid" 2> /dev/null || true
    wait "$openssl_server_pid" 2> /dev/null || true
    if [[ $status -ne 0 || $result != "tls-pure ocsp ok" ]]; then
        echo "tls-ocsp: $version $label: $result" >&2
        failed=1
    fi
}
# The stock client, no setting made: case VERSION LABEL CERTIFICATE STAPLE EXPECTATION(ok|refused) MODE(default|off) ALERT-in-the-server's-log ("-" for none) STATUS-REQUEST(yes|no)
run_default_case() {
    local version=$1 label=$2 cert=$3 staple=$4 expect=$5 mode=$6 alert=$7 offered=$8
    local options=(-cert "$cert.pem" -key "$cert.key" -$version -www -msg -tlsextdebug)
    [[ $staple == none ]] || options+=(-status_file "$staple.resp")
    openssl_server_start server.log '[::1]:0' "${options[@]}" || { echo "tls-ocsp: no server for $version default $label" >&2; failed=1; return; }
    local result status=0
    result=$(timeout 30 ./ocsp-default "$openssl_server_port" ca.pem "$expect" "$mode" 2>&1) || status=$?
    kill "$openssl_server_pid" 2> /dev/null || true
    wait "$openssl_server_pid" 2> /dev/null || true
    if [[ $status -ne 0 || $result != "tls-pure ocsp-default ok" ]]; then
        echo "tls-ocsp: $version default $label: $result" >&2
        failed=1
    fi
    local carried=no
    grep -q 'status request' server.log && carried=yes
    if [[ $carried != "$offered" ]]; then
        echo "tls-ocsp: $version default $label: the ClientHello carried status_request: $carried, expected $offered" >&2
        failed=1
    fi
    if [[ $alert != - ]] && ! grep -q "fatal $alert" server.log; then
        echo "tls-ocsp: $version default $label: the server did not log the alert '$alert'" >&2
        failed=1
    fi
}
for version in tls1_3 tls1_2; do
    run_case $version "good staple, policy staple" leaf leaf ok 1 0
    run_case $version "good staple, policy require" leaf leaf ok 2 0
    run_case $version "revoked certificate, revoked staple" leafrevoked leafrevoked "is revoked" 1 0
    run_case $version "a staple for another certificate" leaf leafrevoked "not acceptable" 1 0
    run_case $version "no staple, policy staple" leaf none ok 1 0
    run_case $version "no staple, policy require" leaf none "no OCSP staple" 2 0
    run_case $version "must-staple without a staple" leafmust none "must-staple" 1 0
    run_case $version "must-staple with a staple" leafmust leafmust ok 1 0
    run_case $version "expired staple" leaf leaf "expired" 1 $((8 * 86400))
    run_case $version "revocation off ignores a revoked staple" leafrevoked leafrevoked ok 0 0
    run_default_case $version "good staple" leaf leaf ok default - yes
    run_default_case $version "no staple" leaf none ok default - yes
    run_default_case $version "revoked staple" leafrevoked leafrevoked refused default certificate_revoked yes
    run_default_case $version "a staple for another certificate" leaf leafrevoked refused default bad_certificate_status_response yes
    run_default_case $version "a staple good for eleven days" leaf leaflong refused default bad_certificate_status_response yes
    run_default_case $version "a staple good for ten days" leaf leafmax ok default - yes
    run_default_case $version "must-staple without a staple" leafmust none refused default bad_certificate yes
    run_default_case $version "revocation 0: no status_request, a revoked staple is ignored" leafrevoked leafrevoked ok off - no
done
[[ $failed -eq 0 ]] || exit 1
echo "tls-ocsp: OCSP stapling against openssl s_server in TLS 1.3 and 1.2: good, revoked, other certificate, expired, absent, must-staple, and off; the stock client checks staples by default"
