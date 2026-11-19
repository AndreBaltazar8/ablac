#!/usr/bin/env bash
# abla/tls/pure against `openssl s_server -tls1_3`, with the real certificate check (abla/crypto/x509 on the
# server's self-signed certificate as the trust anchor, then the CertificateVerify under its key): one run per
# certificate type (Ed25519, ECDSA P-256, ECDSA P-384, RSA-2048 with RSA-PSS), cipher suite (AES-128-GCM, AES-256-GCM, ChaCha20-Poly1305) and key-exchange
# group (X25519, and P-256 only, which makes the server send a HelloRetryRequest), each with a request and
# response, close_notify and a wrong-host-name refusal; then a 6 MB download (tests/cases/tls-pure/bulk.ab).
# Skipped, with a message, without an openssl that does TLS 1.3 and Ed25519. Usage:
#   tools/test-tls-pure-interop.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
. "$root/tools/lib/openssl-server.sh"
out=build/tls-pure-interop
rm -rf "$out"
mkdir -p "$out"
if ! command -v openssl > /dev/null || ! openssl genpkey -algorithm ED25519 -out "$out/ed25519.key" 2> /dev/null; then
    echo 'tls-pure interop: no openssl with Ed25519; skipped'
    exit 0
fi
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/p256.key" 2> /dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$out/p384.key" 2> /dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$out/rsa.key" 2> /dev/null
for kind in ed25519 p256 p384 rsa; do
    openssl req -x509 -new -key "$out/$kind.key" -out "$out/$kind.pem" -subj /CN=localhost \
        -addext 'subjectAltName=DNS:localhost' -days 2 2> /dev/null
done
# The programs, built up front, four at once: they read nothing at compile time, and built one before each use they
# were most of this test's wall time (11 release builds of about 10 s, 2026-11-15).
programs=(interop dropnotify binding-interop api identity mtls tls12prf server sni wipe serve unix bulk)
pids=()
for program in "${programs[@]}"; do
    while (( $(jobs -rp | wc -l) >= 4 )); do sleep 0.2; done
    "$compiler" build "tests/cases/tls-pure/$program.ab" -o "$out/$program" --no-cache > "$out/$program.build.log" 2>&1 &
    pids+=("$!")
done
for index in "${!programs[@]}"; do
    wait "${pids[$index]}" || { cat "$out/${programs[$index]}.build.log" >&2; echo "tls-pure interop: ${programs[$index]} did not build" >&2; exit 1; }
done
server_pid=
trap '[[ -z $server_pid ]] || kill "$server_pid" 2> /dev/null || true' EXIT
# Starts s_server for the key kind with the given options on a free port (in $port), in $server_directory
# (default the current one). A port someone else (a parallel suite) took in between makes the bind fail:
# pick another and try again, a few times.
start_server() {
    local kind=$1
    shift
    # s_server binds [::1] on a port the kernel picks (the helper reads it from its ACCEPT line): no random port in the
    # ephemeral range for a parallel suite's outgoing connection to hold, and the address every client of this script
    # connects to (the name "localhost" is ::1 here), so no family is left to chance. (A test hook: TLS_PURE_FIRST_PORT
    # forces the first attempt of each start onto a port, to exercise the retry.)
    OPENSSL_SERVER_DIR="${server_directory:-.}" OPENSSL_SERVER_FIRST_BIND="${TLS_PURE_FIRST_PORT:+[::1]:$TLS_PURE_FIRST_PORT}" \
        openssl_server_start "$out/server.log" "[::1]:0" -cert "$root/$out/$kind.pem" -key "$root/$out/$kind.key" ${tls_flag:--tls1_3} "$@" ||
        { echo "tls-pure interop: s_server did not start" >&2; exit 1; }
    port=$openssl_server_port
    server_pid=$openssl_server_pid
}
show_port() {   # what the kernel knows about $port, for a failure that says tcp_connect while s_server logged ACCEPT
    command -v ss > /dev/null || return 0
    echo "tls-pure interop: sockets on port $port (ss -tanp), s_server pid ${server_pid:-none}:" >&2
    ss -tanp "( sport = :$port or dport = :$port )" 2>&1 | head -12 >&2
    echo "s_server log: $(head -3 "$out/server.log" 2> /dev/null)" >&2
}
stop_server() {
    kill "$server_pid" 2> /dev/null || true
    wait "$server_pid" 2> /dev/null || true
    server_pid=
}
runs=0
for kind in ed25519 p256 p384 rsa; do
    for suite in TLS_AES_128_GCM_SHA256:4865 TLS_AES_256_GCM_SHA384:4866 TLS_CHACHA20_POLY1305_SHA256:4867; do
        # The groups: X25519 (a share in the hello) and P-256 (a HelloRetryRequest); and, for one key kind, P-384 (HelloRetryRequest) and the
        # hybrid X25519MLKEM768 (the first share), where s_server offers that group only, so the handshake proves it was the one used.
        groups="X25519 P-256"
        [[ $kind == ed25519 ]] && groups="$groups secp384r1 X25519MLKEM768"
        for group in $groups; do
            start_server "$kind" -www -ciphersuites "${suite%:*}" -groups "$group"
            result=$("$root/tools/run-limited.sh" "$out/interop" "$port" "$out/$kind.pem" "${suite#*:}" "$out/$([[ $kind == p256 ]] && echo rsa || echo p256).pem") || {
                echo "tls-pure interop ($kind ${suite%:*} $group): $result" >&2; head -5 "$out/server.log" >&2; show_port; exit 1; }
            [[ $result == 'tls-pure interop ok'* ]] || { echo "tls-pure interop ($kind ${suite%:*} $group): $result" >&2; show_port; exit 1; }
            # The alert each refusal sent (RFC 8446 section 6.2): wrong host name, expired and untrusted certificates.
            # s_server logs a connection's alert when it gets to it, after the client program has exited (the expired case
            # is the client's last connection): wait for each line, up to 20 s, rather than look once.
            for alert in 'alert bad certificate' 'alert certificate expired' 'alert unknown ca'; do
                for _ in $(seq 200); do grep -q "$alert" "$out/server.log" && break; sleep 0.1; done
                grep -q "$alert" "$out/server.log" || { echo "tls-pure interop ($kind ${suite%:*} $group): s_server never saw 'tlsv1 $alert':" >&2; cat "$out/server.log" >&2; exit 1; }
            done
            stop_server
            runs=$((runs + 1))
        done
    done
    echo "$kind: ok"
done
echo "$runs handshakes (4 certificate types x 3 suites x 2 groups, and Ed25519 x 3 suites x P-384 and X25519MLKEM768; P-256 and P-384 go through a HelloRetryRequest)"
# A TlsConnection that is dropped (never close()d) tells the peer: s_server -msg logs the close_notify it received.
start_server ed25519 -www -msg
result=$("$root/tools/run-limited.sh" "$out/dropnotify" "$port" "$out/ed25519.pem") || {
    echo "tls-pure dropnotify: $result" >&2; head -5 "$out/server.log" >&2; exit 1; }
[[ $result == 'tls-pure dropnotify ok' ]] || { echo "tls-pure dropnotify: $result" >&2; exit 1; }
for _ in $(seq 50); do grep -q '<<< TLS 1.3, Alert \[length 0002\], warning close_notify' "$out/server.log" && break; sleep 0.1; done
grep -q '<<< TLS 1.3, Alert \[length 0002\], warning close_notify' "$out/server.log" ||
    { echo "tls-pure dropnotify: the server never saw a close_notify from the dropped connection" >&2; tail -8 "$out/server.log" >&2; exit 1; }
stop_server
echo "drop: the dropped connection sent close_notify"
# Channel bindings (abla/tls/pure/binding) against OpenSSL: tls-exporter equals what s_server -keymatexport prints for the same
# connection (RFC 9266: label EXPORTER-Channel-Binding, empty context, 32 bytes), tls-server-end-point the SHA-256 of the
# server's DER certificate (the P-256 certificate is signed with ecdsa-with-SHA256, RFC 5929).
# (A plain s_server, not -www, prints the keying material; it exits when its stdin ends, so it reads one that stays open.)
OPENSSL_SERVER_INHERIT_STDIN=1 start_server p256 -keymatexport EXPORTER-Channel-Binding -keymatexportlen 32 < <(sleep 60)
result=$("$root/tools/run-limited.sh" "$out/binding-interop" "$port" "$out/p256.pem") || {
    echo "tls-pure binding: $result" >&2; head -5 "$out/server.log" >&2; exit 1; }
read -r _ got_exporter got_endpoint <<< "$result"
for _ in $(seq 50); do grep -q 'Keying material: ' "$out/server.log" && break; sleep 0.1; done
want_exporter=$(sed -n 's/.*Keying material: \([0-9A-Fa-f]*\).*/\1/p' "$out/server.log" | head -1 | tr 'A-F' 'a-f')
want_endpoint=$(openssl x509 -in "$out/p256.pem" -outform DER | openssl dgst -sha256 -binary | od -An -v -tx1 | tr -d ' \n')
[[ -n $want_exporter && $got_exporter == "$want_exporter" ]] ||
    { echo "tls-pure binding: tls-exporter '$got_exporter', OpenSSL '$want_exporter'" >&2; cat "$out/server.log" >&2; exit 1; }
[[ $got_endpoint == "$want_endpoint" ]] || { echo "tls-pure binding: tls-server-end-point '$got_endpoint', expected '$want_endpoint'" >&2; exit 1; }
stop_server
echo "binding: tls-exporter and tls-server-end-point agree with OpenSSL"
# TLS 1.2 (the modern subset): the pure client against `openssl s_server -tls1_2`: RSA, P-256 and Ed25519 certificates x their six
# ECDHE suites x X25519 and P-256, and RSA with PKCS#1 v1.5 signatures only; a TLS 1.2 server without the extended
# master secret is refused.
runs12=0
# (A TLS 1.2 server requires the certificate's curve in the client's supported_groups: the P-384 certificate works because the client offers
# P-384 for ECDHE too.)
for kind in rsa p256 p384 ed25519; do
    if [[ $kind == rsa ]]; then
        suites12="ECDHE-RSA-AES128-GCM-SHA256:49199 ECDHE-RSA-AES256-GCM-SHA384:49200 ECDHE-RSA-CHACHA20-POLY1305:52392"
    else
        suites12="ECDHE-ECDSA-AES128-GCM-SHA256:49195 ECDHE-ECDSA-AES256-GCM-SHA384:49196 ECDHE-ECDSA-CHACHA20-POLY1305:52393"
    fi
    for suite in $suites12; do
        groups12="X25519 P-256"
        [[ $kind == ed25519 || $kind == p384 ]] && groups12="$groups12 secp384r1"
        for group in $groups12; do
            tls_flag=-tls1_2 start_server "$kind" -www -cipher "${suite%:*}" -groups "$group"
            result=$("$root/tools/run-limited.sh" "$out/interop" "$port" "$out/$kind.pem" "${suite#*:}" "$out/$([[ $kind == p256 ]] && echo rsa || echo p256).pem") || {
                echo "tls-pure TLS 1.2 ($kind ${suite%:*} $group): $result" >&2; head -5 "$out/server.log" >&2; show_port; exit 1; }
            [[ $result == 'tls-pure interop ok'* ]] || { echo "tls-pure TLS 1.2 ($kind ${suite%:*} $group): $result" >&2; show_port; exit 1; }
            stop_server
            runs12=$((runs12 + 1))
        done
    done
done
tls_flag=-tls1_2 start_server rsa -www -cipher ECDHE-RSA-AES128-GCM-SHA256 -groups X25519
result=$("$root/tools/run-limited.sh" "$out/interop" "$port" "$out/rsa.pem" 49199 "$out/p256.pem" pkcs1) || { echo "tls-pure TLS 1.2 (RSA PKCS#1): $result" >&2; head -5 "$out/server.log" >&2; show_port; exit 1; }
[[ $result == 'tls-pure interop ok'* ]] || { echo "tls-pure TLS 1.2 (RSA PKCS#1): $result" >&2; show_port; exit 1; }
stop_server
runs12=$((runs12 + 1))
echo "TLS 1.2: $runs12 handshakes (4 certificate types x 3 suites x 2 groups, P-384 ECDHE for Ed25519 and P-384 certificates, and RSA with PKCS#1 v1.5)"
# The hosted-API-compatible surface (abla/tls/pure: tlsConnectWithCa, TlsConnection, tlsLastError ...).
start_server ed25519 -www -groups X25519
result=$("$root/tools/run-limited.sh" "$out/api" "$port" "$out/ed25519.pem" "$out/rsa.pem") || { echo "tls-pure api: $result" >&2; head -5 "$out/server.log" >&2; exit 1; }
[[ $result == 'tls-pure api ok' ]] || { echo "tls-pure api: $result" >&2; exit 1; }
echo "$result"
stop_server
# Client identities from PEM (every key kind and encoding), then mutual TLS: s_server -Verify trusting one client
# certificate; that client is accepted, one with no identity and one with another certificate are refused. (TLS 1.2 needs the client certificate's curve in the server's groups: hence X25519:P-256.)
openssl rsa -in "$out/rsa.key" -traditional -out "$out/rsa-alt.key" 2> /dev/null
openssl ec -in "$out/p256.key" -out "$out/p256-alt.key" 2> /dev/null
openssl ec -in "$out/p384.key" -out "$out/p384-alt.key" 2> /dev/null
openssl pkcs8 -topk8 -v2 aes-256-cbc -iter 2000 -in "$out/rsa.key" -passout pass:secret -out "$out/rsa-enc.key" 2> /dev/null
# PKCS#12 containers (OpenSSL 3's defaults: PBES2 AES-256-CBC, SHA-256 MAC) for the identity test and one mutual-TLS run:
# one per key kind (the server certificates), the client certificates, and a chain (a CA and a leaf it signed).
for kind in rsa p256 p384 ed25519; do
    openssl pkcs12 -export -inkey "$out/$kind.key" -in "$out/$kind.pem" -out "$out/$kind.p12" -passout pass:secret 2> /dev/null
done
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$out/chain-ca.key" -out "$out/chain-ca.pem" -subj /CN=chain-ca -days 2 2> /dev/null
openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$out/chain-leaf.key" -out "$out/chain-leaf.csr" -subj /CN=chain-leaf 2> /dev/null
openssl x509 -req -in "$out/chain-leaf.csr" -CA "$out/chain-ca.pem" -CAkey "$out/chain-ca.key" -CAcreateserial -out "$out/chain-leaf.pem" -days 2 2> /dev/null
openssl pkcs12 -export -inkey "$out/chain-leaf.key" -in "$out/chain-leaf.pem" -certfile "$out/chain-ca.pem" -out "$out/chain.p12" -passout pass:secret 2> /dev/null
result=$("$root/tools/run-limited.sh" "$out/identity" "$out") || { echo "tls-pure identity: $result" >&2; exit 1; }
[[ $result == 'tls-pure identity ok' ]] || { echo "tls-pure identity: $result" >&2; exit 1; }
echo "$result"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$out/client-rsa.key" 2> /dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/client-p256.key" 2> /dev/null
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-384 -out "$out/client-p384.key" 2> /dev/null
openssl genpkey -algorithm ED25519 -out "$out/client-ed25519.key" 2> /dev/null
for kind in rsa p256 p384 ed25519; do
    openssl req -x509 -new -key "$out/client-$kind.key" -out "$out/client-$kind.pem" -subj /CN=client-$kind -days 2 2> /dev/null
    openssl pkcs12 -export -inkey "$out/client-$kind.key" -in "$out/client-$kind.pem" -out "$out/client-$kind.p12" -passout pass:secret 2> /dev/null
done
for version in tls1_3 tls1_2; do
for kind in rsa p256 p384 ed25519; do
    other=$([[ $kind == rsa ]] && echo p256 || echo rsa)
    # (OpenSSL checks a TLS 1.2 client certificate's curve against its own groups: a P-384 certificate needs P-384 among them.)
    tls_flag=-$version start_server ed25519 -www -groups X25519:P-256:secp384r1 -Verify 1 -CAfile "$out/client-$kind.pem" -verify_return_error
    for case in "accepted:client-$kind" "refused:none" "refused:client-$other"; do
        expect=${case%%:*}
        who=${case#*:}
        certificate=$([[ $who == none ]] && echo none || echo "$out/$who.pem")
        result=$("$root/tools/run-limited.sh" "$out/mtls" "$port" "$out/ed25519.pem" "$certificate" "$out/$who.key" "$expect") || {
            echo "tls-pure mtls ($kind trusted, $who): $result" >&2; head -5 "$out/server.log" >&2; exit 1; }
        [[ $result == "tls-pure mtls ok ($expect)" ]] || { echo "tls-pure mtls ($kind trusted, $who): $result" >&2; exit 1; }
    done
    # The same client as a PKCS#12 identity.
    result=$("$root/tools/run-limited.sh" "$out/mtls" "$port" "$out/ed25519.pem" "$out/client-$kind.p12" none accepted) || {
        echo "tls-pure mtls (PKCS#12 $kind): $result" >&2; head -5 "$out/server.log" >&2; exit 1; }
    [[ $result == "tls-pure mtls ok (accepted)" ]] || { echo "tls-pure mtls (PKCS#12 $kind): $result" >&2; exit 1; }
    stop_server
    echo "mtls $version $kind: accepted, refused without an identity, refused with another, accepted as PKCS#12"
done
done
# A TLS 1.2 server without the extended master secret is refused (the subset requires it).
tls_flag=-tls1_2 start_server rsa -www -no_ems -cipher ECDHE-RSA-AES128-GCM-SHA256
if result=$("$root/tools/run-limited.sh" "$out/interop" "$port" "$out/rsa.pem" 49199 "$out/p256.pem" 2>&1); then
    echo "tls-pure TLS 1.2: a server without the extended master secret was accepted: $result" >&2; exit 1
fi
[[ $result == *'extended master secret'* ]] || { echo "tls-pure TLS 1.2: refused for another reason: $result" >&2; exit 1; }
stop_server
echo 'TLS 1.2: a server without the extended master secret is refused'
# TLS 1.2 building blocks: the PRF against `openssl kdf TLS1-PRF` (random secrets and seeds, SHA-256 and SHA-384, the
# labels TLS 1.2 uses), the key block, the AEAD record layer for three suites, the message codecs.
hex() { od -An -vtx1 | tr -d ' \n'; }
prf_args=()
for spec in "SHA256 48 master secret" "SHA256 12 client finished" "SHA384 104 key expansion" "SHA384 12 server finished" "SHA256 104 key expansion" "SHA384 48 extended master secret"; do
    set -- $spec
    digest=$1; length=$2; shift 2; label="$*"
    secret=$(head -c 48 /dev/urandom | hex); seed=$(head -c 64 /dev/urandom | hex)
    expected=$(openssl kdf -keylen "$length" -kdfopt digest:"$digest" -kdfopt hexsecret:"$secret" -kdfopt hexseed:"$(printf %s "$label" | hex)$seed" TLS1-PRF 2> /dev/null | tr -d ':' | tr 'A-F' 'a-f') || expected=
    if [[ -z $expected ]]; then echo 'tls-pure tls12: this openssl has no kdf TLS1-PRF; the PRF is not compared'; prf_args=(); break; fi
    prf_args+=("$digest" "$secret" "$label" "$seed" "$length" "$expected")
done
result=$("$root/tools/run-limited.sh" "$out/tls12prf" "${prf_args[@]}") || { echo "tls-pure tls12 blocks: $result" >&2; exit 1; }
[[ $result == 'tls-pure tls12 ok'* ]] || { echo "tls-pure tls12 blocks: $result" >&2; exit 1; }
echo "$result"
# The sans-IO server against the sans-IO client in one process (tests/cases/tls-pure/server.ab): every key kind x suite x
# group (HelloRetryRequest), 70 KB each way, ALPN, client certificates, KeyUpdate, refusals, damaged input.
result=$("$root/tools/run-limited.sh" "$out/server" "$out") || { echo "tls-pure server (in process): $result" >&2; exit 1; }
[[ $result == 'tls-pure server ok' ]] || { echo "tls-pure server (in process): $result" >&2; exit 1; }
echo "$result"
result=$("$root/tools/run-limited.sh" "$out/sni" "$out") || { echo "tls-pure sni (in process): $result" >&2; exit 1; }
[[ $result == 'tls-pure sni ok' ]] || { echo "tls-pure sni (in process): $result" >&2; exit 1; }
echo "$result"
# Secrets cleared once nothing reads them (tests/cases/tls-pure/wipe.ab): key shares, handshake and master secrets, old
# traffic secrets and keys after KeyUpdate, everything at close and failure, TLS 1.2's ephemeral key and master secret,
# identities' keys (PEM and PKCS#12) on wipe(), a listener's on close.
result=$("$root/tools/run-limited.sh" "$out/wipe" "$out") || { echo "tls-pure wipe: $result" >&2; exit 1; }
[[ $result == 'tls-pure wipe ok' ]] || { echo "tls-pure wipe: $result" >&2; exit 1; }
echo "$result"
# abla/tls/pure as the SERVER: tests/cases/tls-pure/serve.ab (listening on ::1 on a free port) against openssl s_client
# (every key kind x cipher suite x group, so the P-256 ones through a HelloRetryRequest), against the pure client,
# with ALPN, and requiring a client certificate.
serve_pid=
stop_serve() {
    [[ -z $serve_pid ]] || { kill "$serve_pid" 2> /dev/null || true; wait "$serve_pid" 2> /dev/null || true; }
    serve_pid=
}
trap 'stop_serve; [[ -z $server_pid ]] || kill "$server_pid" 2> /dev/null || true' EXIT
start_serve() {   # the serve.ab arguments; sets serve_port
    # Empty the log HERE, before the child starts: a log that only the child's own redirection truncates still holds the previous
    # server's "listening" line until that process gets to run, and on a loaded machine the grep below can run first, see it,
    # and have the sed that reads the port find the log empty by then (the failure said "no port after 120 s" after 35 ms).
    : > "$out/serve.log"
    "$out/serve" "$@" > "$out/serve.log" 2>&1 &
    serve_pid=$!
    # Up to 120 s by the clock (not by counting iterations: under load each iteration takes more than its sleep); one
    # that died stops the wait at once. A failure says what the process was doing.
    local until=$(( SECONDS + 120 ))
    while (( SECONDS < until )); do
        grep -q '^listening ' "$out/serve.log" 2> /dev/null && break
        kill -0 "$serve_pid" 2> /dev/null || { echo "tls-pure serve: did not start: $(head -3 "$out/serve.log")" >&2; exit 1; }
        sleep 0.1
    done
    serve_port=$(sed -n 's/^listening //p' "$out/serve.log" | head -1)
    [[ -n $serve_port ]] || { echo "tls-pure serve: no port after 120 s (process $(kill -0 "$serve_pid" 2> /dev/null && echo alive || echo gone), state $(sed -n 's/^State:\s*//p' "/proc/$serve_pid/status" 2> /dev/null | head -1), wchan $(cat "/proc/$serve_pid/wchan" 2> /dev/null), CPU used and time waiting in the run queue (ns) $(cat "/proc/$serve_pid/schedstat" 2> /dev/null), utime/stime ticks $(cut -d" " -f14,15 "/proc/$serve_pid/stat" 2> /dev/null), context switches $(grep ctxt_switches "/proc/$serve_pid/status" 2> /dev/null | tr -s "\n\t " " "), load $(cut -d" " -f1-3 /proc/loadavg)): $(head -3 "$out/serve.log")" >&2; exit 1; }
}
s_client() {   # the s_client options after the address; prints what the server sent
    printf 'GET /pure HTTP/1.0\r\n\r\n' | timeout 15 openssl s_client -connect "[::1]:$serve_port" ${s_tls:--tls1_3} -servername localhost -quiet "$@" 2> "$out/s_client.err" || true
}
negotiated() {   # the s_client options after the address; prints the key exchange s_client -brief reports: the TLS 1.3 group (X25519MLKEM768) or the temporary key ("ECDH, secp384r1, 384 bits")
    printf 'GET /pure HTTP/1.0\r\n\r\n' | timeout 15 openssl s_client -connect "[::1]:$serve_port" ${s_tls:--tls1_3} -servername localhost -brief "$@" > "$out/s_client.out" 2> "$out/s_client.err" || true
    sed -n 's/^Negotiated TLS1.3 group: //p; s/^Peer Temp Key: //p' "$out/s_client.err"
}
served=0
for kind in ed25519 p256 p384 rsa; do
    start_serve plain "$out/$kind.pem" "$out/$kind.key"
    for suite in TLS_AES_128_GCM_SHA256 TLS_AES_256_GCM_SHA384 TLS_CHACHA20_POLY1305_SHA256; do
        groups="X25519 P-256"
        [[ $kind == ed25519 ]] && groups="$groups secp384r1 X25519MLKEM768"
        for group in $groups; do
            answer=$(s_client -ciphersuites "$suite" -groups "$group" -CAfile "$out/$kind.pem" -verify_return_error -verify_hostname localhost)
            [[ $answer == *'pure server: GET /pure'* ]] || { echo "tls-pure server ($kind $suite $group): [$answer] $(head -3 "$out/s_client.err") $(head -3 "$out/serve.log")" >&2; exit 1; }
            served=$((served + 1))
        done
    done
    # What the group of a handshake was (not only that it worked): the hybrid, and P-384 (with only X25519's share sent first: a
    # HelloRetryRequest). The s_client default (no -groups) is not asked about: it depends on the OpenSSL version.
    if [[ $kind == ed25519 ]]; then
        [[ $(negotiated -groups X25519MLKEM768 -CAfile "$out/$kind.pem") == X25519MLKEM768 ]] || { echo "tls-pure server: the hybrid was not negotiated: $(cat "$out/s_client.err")" >&2; exit 1; }
        [[ $(negotiated -groups secp384r1 -CAfile "$out/$kind.pem") == 'ECDH, secp384r1, 384 bits' ]] || { echo "tls-pure server: P-384 was not negotiated: $(cat "$out/s_client.err")" >&2; exit 1; }
        [[ $(negotiated -groups X25519:X25519MLKEM768 -CAfile "$out/$kind.pem") == 'X25519, 253 bits' ]] || { echo "tls-pure server: X25519 was not chosen over a retry: $(cat "$out/s_client.err")" >&2; exit 1; }
    fi
    # The pure client against it (one good connection, a wrong host name, an untrusted anchor).
    result=$("$root/tools/run-limited.sh" "$out/interop" "$serve_port" "$out/$kind.pem" 4865 "$out/$([[ $kind == p256 ]] && echo rsa || echo p256).pem") || {
        echo "tls-pure client vs pure server ($kind): $result" >&2; head -3 "$out/serve.log" >&2; exit 1; }
    [[ $result == 'tls-pure interop ok'* ]] || { echo "tls-pure client vs pure server ($kind): $result" >&2; exit 1; }
    stop_serve
done
echo "pure server: $served openssl s_client handshakes (4 key kinds x 3 suites x 2 groups, Ed25519 also P-384 and X25519MLKEM768, which of them was negotiated, and one-group servers that send a HelloRetryRequest) and the pure client, each key kind"
# A server with one group: P-384, and the hybrid. s_client sends a share for the first of its groups (X25519) only, so the server must answer
# with a HelloRetryRequest and s_client must retry with the group the server wants.
start_serve p384 "$out/ed25519.pem" "$out/ed25519.key"
[[ $(negotiated -groups X25519:secp384r1 -CAfile "$out/ed25519.pem") == 'ECDH, secp384r1, 384 bits' ]] || { echo "tls-pure server (P-384 only): no HelloRetryRequest to P-384: $(cat "$out/s_client.err")" >&2; exit 1; }
stop_serve
start_serve hybrid "$out/ed25519.pem" "$out/ed25519.key"
[[ $(negotiated -groups X25519:X25519MLKEM768 -CAfile "$out/ed25519.pem") == X25519MLKEM768 ]] || { echo "tls-pure server (hybrid only): no HelloRetryRequest to the hybrid: $(cat "$out/s_client.err")" >&2; exit 1; }
answer=$(s_client -groups X25519 -CAfile "$out/ed25519.pem" -verify_return_error)
[[ $answer != *'pure server'* ]] || { echo "tls-pure server (hybrid only): a client without the hybrid was served: [$answer]" >&2; exit 1; }
stop_serve
# The same server speaks TLS 1.2 to openssl s_client -tls1_2: every key kind x its suites x X25519 / P-256, then a client certificate.
served12=0
for kind in ed25519 p256 p384 rsa; do
    start_serve plain "$out/$kind.pem" "$out/$kind.key"
    if [[ $kind == rsa ]]; then
        suites12="ECDHE-RSA-AES128-GCM-SHA256 ECDHE-RSA-AES256-GCM-SHA384 ECDHE-RSA-CHACHA20-POLY1305"
    else
        suites12="ECDHE-ECDSA-AES128-GCM-SHA256 ECDHE-ECDSA-AES256-GCM-SHA384 ECDHE-ECDSA-CHACHA20-POLY1305"
    fi
    for suite in $suites12; do
        groups12="X25519 P-256"
        [[ $kind == ed25519 ]] && groups12="$groups12 secp384r1"
        for group in $groups12; do
            # (A TLS 1.2 client must offer the certificate's curve: P-256 for the P-256 key, P-384 for the P-384 key, beside the group tried.)
            offered=$group
            [[ $kind == p256 && $group != P-256 ]] && offered=$group:P-256
            [[ $kind == p384 && $group != secp384r1 ]] && offered=$group:secp384r1
            answer=$(s_tls=-tls1_2 s_client -cipher "$suite" -groups "$offered" -CAfile "$out/$kind.pem" -verify_return_error -verify_hostname localhost)
            [[ $answer == *'pure server: GET /pure'* ]] || { echo "tls-pure server TLS 1.2 ($kind $suite $group): [$answer] $(head -3 "$out/s_client.err") $(head -3 "$out/serve.log")" >&2; exit 1; }
            served12=$((served12 + 1))
        done
    done
    if [[ $kind == ed25519 ]]; then
        [[ $(s_tls=-tls1_2 negotiated -cipher ECDHE-ECDSA-AES128-GCM-SHA256 -groups secp384r1 -CAfile "$out/$kind.pem") == 'ECDH, secp384r1, 384 bits' ]] ||
            { echo "tls-pure server TLS 1.2: P-384 was not negotiated: $(cat "$out/s_client.err")" >&2; exit 1; }
    fi
    stop_serve
done
start_serve auth "$out/ed25519.pem" "$out/ed25519.key" "$out/client-p256.pem"
answer=$(s_tls=-tls1_2 s_client -CAfile "$out/ed25519.pem" -cert "$out/client-p256.pem" -key "$out/client-p256.key")
[[ $answer == *'client=true'* ]] || { echo "tls-pure server TLS 1.2 client certificate: [$answer] $(head -3 "$out/s_client.err") $(head -3 "$out/serve.log")" >&2; exit 1; }
answer=$(s_tls=-tls1_2 s_client -CAfile "$out/ed25519.pem")
[[ $answer != *'pure server'* ]] || { echo "tls-pure server TLS 1.2: a client with no certificate was served: [$answer]" >&2; exit 1; }
stop_serve
echo "pure server: $served12 openssl s_client -tls1_2 handshakes (4 key kinds x 3 suites x 2 groups, Ed25519 also P-384 ECDHE) and a required client certificate"
# Session resumption, our server (ticket keys, two tickets per connection) with openssl s_client: -sess_out keeps the ticket of one connection,
# -sess_in resumes it (s_client says "Reused", and the server's answer says resumed=true); a second resumption from the new ticket of the first.
start_serve tickets "$out/ed25519.pem" "$out/ed25519.key"
resume_client() {   # the s_client options: prints what the server answered; s_client's own report is in s_client.out
    printf 'GET /pure HTTP/1.0\r\n\r\n' | timeout 15 openssl s_client -connect "[::1]:$serve_port" -tls1_3 -ign_eof -servername localhost -CAfile "$out/ed25519.pem" -verify_return_error "$@" > "$out/s_client.out" 2> "$out/s_client.err" || true
    sed -n 's/^pure server: //p' "$out/s_client.out"
}
answer=$(resume_client -sess_out "$out/session.pem")
[[ $answer == *'resumed=false'* ]] || { echo "tls-pure server resumption: the first connection: [$answer] $(head -3 "$out/s_client.err")" >&2; exit 1; }
[[ -s $out/session.pem ]] || { echo "tls-pure server resumption: s_client kept no session (no ticket arrived)" >&2; exit 1; }
for round in 1 2; do
    answer=$(resume_client -sess_in "$out/session.pem" -sess_out "$out/session.pem")
    [[ $answer == *'resumed=true'* && $(grep -c 'Reused, TLSv1.3' "$out/s_client.out") -ge 1 ]] ||
        { echo "tls-pure server resumption: round $round did not resume: [$answer] $(head -3 "$out/s_client.err")" >&2; sed -n 1,20p "$out/s_client.out" >&2; exit 1; }
done
stop_serve
echo "pure server: session resumption with openssl s_client -sess_out/-sess_in, twice"
# And the pure client resuming from openssl s_server's tickets, blocking and through abla/http/async (tests/cases/tls-pure/resume-net.ab).
"$compiler" build tests/cases/tls-pure/resume-net.ab -o "$out/resume-net" --no-cache
for mode in blocking async; do
    OPENSSL_SERVER_DIR="${server_directory:-.}" openssl_server_start "$out/server.log" "0" -cert "$root/$out/ed25519.pem" -key "$root/$out/ed25519.key" -tls1_3 -www -num_tickets 2 ||
        { echo "tls-pure resumption: s_server did not start" >&2; exit 1; }
    result=$("$root/tools/run-limited.sh" "$out/resume-net" "$openssl_server_port" "$out/ed25519.pem" "$mode") || { echo "tls-pure resume-net ($mode): $result" >&2; kill "$openssl_server_pid" 2> /dev/null; exit 1; }
    [[ $result == 'tls-pure resume-net ok' ]] || { echo "tls-pure resume-net ($mode): $result" >&2; kill "$openssl_server_pid" 2> /dev/null; exit 1; }
    kill "$openssl_server_pid" 2> /dev/null || true
    wait "$openssl_server_pid" 2> /dev/null || true
done
echo "pure client: session resumption from s_server's tickets, blocking and through abla/http/async"
# The in-process resumption tests (tests/cases/tls-pure/resume.ab): tickets, expiry, rotation, HelloRetryRequest with a PSK, binders, wipes.
"$compiler" build tests/cases/tls-pure/resume.ab -o "$out/resume" --no-cache
result=$("$root/tools/run-limited.sh" "$out/resume" "$out") || { echo "tls-pure resume (in process): $result" >&2; exit 1; }
[[ $result == 'tls-pure resume ok' ]] || { echo "tls-pure resume (in process): $result" >&2; exit 1; }
echo "$result"
start_serve alpn "$out/ed25519.pem" "$out/ed25519.key"
answer=$(s_client -CAfile "$out/ed25519.pem" -alpn http/1.1,h2)
[[ $answer == *'alpn=h2'* ]] || { echo "tls-pure server ALPN: [$answer] $(head -3 "$out/s_client.err")" >&2; exit 1; }
answer=$(s_client -CAfile "$out/ed25519.pem" -alpn spdy)
[[ $answer != *'pure server'* ]] || { echo "tls-pure server ALPN: a client with no protocol in common was served: [$answer]" >&2; exit 1; }
stop_serve
start_serve auth "$out/ed25519.pem" "$out/ed25519.key" "$out/client-p256.pem"
answer=$(s_client -CAfile "$out/ed25519.pem" -cert "$out/client-p256.pem" -key "$out/client-p256.key")
[[ $answer == *'client=true'* ]] || { echo "tls-pure server client certificate: [$answer] $(head -3 "$out/s_client.err") $(head -3 "$out/serve.log")" >&2; exit 1; }
answer=$(s_client -CAfile "$out/ed25519.pem")
[[ $answer != *'pure server'* ]] || { echo "tls-pure server: a client with no certificate was served: [$answer]" >&2; exit 1; }
answer=$(s_client -CAfile "$out/ed25519.pem" -cert "$out/client-rsa.pem" -key "$out/client-rsa.key")
[[ $answer != *'pure server'* ]] || { echo "tls-pure server: an untrusted client certificate was served: [$answer]" >&2; exit 1; }
stop_serve
echo "pure server: ALPN (server order, none in common refused) and a required client certificate (accepted, absent and untrusted refused)"
# Certificate selection by server name and signature algorithms (tests/cases/tls-pure/sni.ab does the same in memory): the leaf s_client gets
# is compared with the certificate files, for TLS 1.3 and TLS 1.2.
leaf() {   # s_client options: the first certificate the server sent, PEM
    printf '' | timeout 15 openssl s_client -connect "[::1]:$serve_port" -showcerts "$@" 2> "$out/s_client.err" | awk '/BEGIN CERTIFICATE/ {on=1} on {print} /END CERTIFICATE/ {exit}' || true
}
expect_leaf() {   # NAME KIND s_client options
    local name=$1 kind=$2; shift 2
    local got; got=$(leaf "$@")
    [[ $got == "$(cat "$out/$kind.pem")" ]] || { echo "tls-pure server SNI ($name): wanted the $kind certificate, got: ${got%%$'\n'*} $(head -3 "$out/s_client.err")" >&2; exit 1; }
}
start_serve sni "$out/p256.pem" "$out/p256.key" "$out/rsa.pem" "$out/rsa.key" "$out/ed25519.pem" "$out/ed25519.key"
for tls in -tls1_3 -tls1_2; do
    expect_leaf "pair.test $tls" p256 $tls -servername pair.test
    expect_leaf "PAIR.TEST $tls" p256 $tls -servername PAIR.TEST
    expect_leaf "pair.test RSA only $tls" rsa $tls -servername pair.test -sigalgs RSA-PSS+SHA256
    expect_leaf "other.test $tls" p256 $tls -servername other.test
    expect_leaf "no name $tls" p256 $tls -noservername
    expect_leaf "other.test RSA only $tls" rsa $tls -servername other.test -sigalgs RSA-PSS+SHA256
done
expect_leaf "a.wild.test" ed25519 -tls1_3 -servername a.wild.test
expect_leaf "a.b.wild.test" p256 -tls1_3 -servername a.b.wild.test
# A server name served by an Ed25519 certificate to a client that cannot take one is refused, as a single certificate would.
got=$(leaf -tls1_3 -servername a.wild.test -sigalgs RSA-PSS+SHA256)
[[ -z $got ]] || { echo "tls-pure server SNI: a client that takes no Ed25519 was served: $got" >&2; exit 1; }
stop_serve
echo "pure server: SNI (name, wildcard, case, signature algorithms, TLS 1.3 and 1.2) against openssl s_client"
# Unix stream sockets: the pure client over `openssl s_server -unix`, and the pure server over a Unix listener against
# `openssl s_client -unix`.
socket="$out/tls.sock"
rm -f "$socket"
openssl s_server -unix "$socket" -unlink -cert "$out/ed25519.pem" -key "$out/ed25519.key" -tls1_3 -www > "$out/unix-server.log" 2>&1 &
server_pid=$!
for _ in $(seq 300); do [[ -S $socket ]] && break; sleep 0.1; done
result=$("$root/tools/run-limited.sh" "$out/unix" client "$socket" "$out/ed25519.pem") || { echo "tls-pure unix client: $result" >&2; head -5 "$out/unix-server.log" >&2; exit 1; }
[[ $result == 'tls-pure unix client ok'* ]] || { echo "tls-pure unix client: $result" >&2; exit 1; }
stop_server
rm -f "$socket"
"$out/unix" server "$socket" "$out/ed25519.pem" "$out/ed25519.key" > "$out/unix-serve.log" 2>&1 &
serve_pid=$!
for _ in $(seq 300); do [[ -S $socket ]] && break; sleep 0.1; done
answer=$(printf 'GET /unix HTTP/1.0\r\n\r\n' | timeout 15 openssl s_client -unix "$socket" -tls1_3 -servername localhost -CAfile "$out/ed25519.pem" -verify_return_error -verify_hostname localhost -quiet 2> "$out/s_client.err" || true)
[[ $answer == *'unix pure server:'* ]] || { echo "tls-pure unix server: [$answer] $(head -3 "$out/s_client.err") $(head -3 "$out/unix-serve.log")" >&2; exit 1; }
wait "$serve_pid" 2> /dev/null || true
serve_pid=
rm -f "$socket"
echo 'tls-pure unix: the client over s_server -unix and the server for s_client -unix'
# A bulk transfer: a 6 MB file, many records; size and SHA-256 must match (Ed25519, checked in the program).
mkdir -p "$out/www"
head -c 6291456 /dev/urandom > "$out/www/big.bin"
expected=$(sha256sum "$out/www/big.bin" | cut -d' ' -f1)
public=$(openssl pkey -in "$out/ed25519.key" -pubout -outform DER | tail -c 32 | od -An -vtx1 | tr -d ' \n')
server_directory="$out/www" start_server ed25519 -HTTP -groups X25519
result=$("$root/tools/run-limited.sh" "$out/bulk" "$port" "$public" /big.bin 6291456 "$expected") || { echo "tls-pure bulk: $result" >&2; head -5 "$out/server.log" >&2; exit 1; }
[[ $result == 'tls-pure bulk ok'* ]] || { echo "tls-pure bulk: $result" >&2; exit 1; }
echo "$result"
stop_server
echo 'tls-pure interop ok'
