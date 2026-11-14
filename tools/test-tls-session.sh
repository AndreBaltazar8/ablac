#!/usr/bin/env bash
# abla/tls/pure's TlsSession (a client over a non-blocking socket the program polls itself) against `openssl s_server`:
# the verification modes (none, chain, host) with good, wrong-name and wrong-CA certificates, an IP address as the
# host (an IP subjectAltName, no server name sent), TLS 1.3 and TLS 1.2, a request and a response read to the end,
# a flood of writes into a server that stopped reading (the session must say want-write, and a partial send is
# resumed), and a handshake against a server that stays silent (want-read).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/tls-session
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tests/cases/tls-pure/session.ab -o "$out/session" --no-cache
server_pid=
trap '[[ -z $server_pid ]] || kill -CONT "$server_pid" 2> /dev/null; [[ -z $server_pid ]] || kill "$server_pid" 2> /dev/null || true' EXIT
make_cert() {   # name, subjectAltName
    openssl genpkey -algorithm ED25519 -out "$out/$1.key" 2> /dev/null
    openssl req -x509 -new -key "$out/$1.key" -days 2 -subj /CN=localhost -addext "subjectAltName=$2" -out "$out/$1.pem" 2> /dev/null
}
make_cert good "DNS:localhost,IP:127.0.0.1,IP:::1"
make_cert other "DNS:localhost,IP:127.0.0.1,IP:::1"
make_cert dnsonly "DNS:localhost"
start_server() {   # certificate name, then s_server options; sets port
    local name=$1 attempt
    shift
    for attempt in 1 2 3 4 5 6 7 8; do
        port=$(( 20000 + RANDOM % 20000 ))
        openssl s_server -accept "$port" -cert "$out/$name.pem" -key "$out/$name.key" "$@" > "$out/server.log" 2>&1 &
        server_pid=$!
        local started=0
        for _ in $(seq 300); do
            if grep -q ACCEPT "$out/server.log" 2> /dev/null; then started=1; break; fi
            kill -0 "$server_pid" 2> /dev/null || break
            sleep 0.1
        done
        [[ $started -eq 1 ]] && return 0
        kill "$server_pid" 2> /dev/null || true
        wait "$server_pid" 2> /dev/null || true
        server_pid=
        grep -q 'Address already in use' "$out/server.log" || break
    done
    echo "tls-session: s_server did not start: $(head -3 "$out/server.log")" >&2
    exit 1
}
stop_server() {
    kill -CONT "$server_pid" 2> /dev/null || true
    kill "$server_pid" 2> /dev/null || true
    wait "$server_pid" 2> /dev/null || true
    server_pid=
}
run() {   # mode host ca family action [pid]
    timeout 120 "$out/session" "$1" "$2" "$port" "$3" "$4" "$5" "${6:-0}" 2> /dev/null | tail -1
}
expect_ok() {
    local what=$1 result=$2
    [[ $result == 'result ok '* ]] || { echo "tls-session ($what): [$result]" >&2; exit 1; }
}
expect_failed() {
    local what=$1 result=$2
    [[ $result == 'result failed '* ]] || { echo "tls-session ($what): wanted a failure, got [$result]" >&2; exit 1; }
}
checks=0
for version in -tls1_3 -tls1_2; do
    start_server good "$version" -www
    expect_ok "host good $version" "$(run host localhost "$out/good.pem" 6 get)"
    expect_failed "host wrong name $version" "$(run host wrong.example "$out/good.pem" 6 get)"
    expect_failed "host wrong CA $version" "$(run host localhost "$out/other.pem" 6 get)"
    expect_ok "chain ignores the name $version" "$(run chain wrong.example "$out/good.pem" 6 get)"
    expect_failed "chain wrong CA $version" "$(run chain localhost "$out/other.pem" 6 get)"
    expect_ok "none trusts nothing $version" "$(run none wrong.example "$out/other.pem" 6 get)"
    expect_ok "host IPv6 address $version" "$(run host ::1 "$out/good.pem" 6 get)"
    stop_server
    checks=$((checks + 7))
done
# An IPv4 address: the certificate needs an IP entry (a DNS name does not do); no server name is sent for it.
start_server good -tls1_3 -www
expect_ok "host IPv4 address" "$(run host 127.0.0.1 "$out/good.pem" 4 get)"
stop_server
start_server dnsonly -tls1_3 -www
expect_failed "host IPv4 address without an IP entry" "$(run host 127.0.0.1 "$out/dnsonly.pem" 4 get)"
expect_ok "chain IPv4 address without an IP entry" "$(run chain 127.0.0.1 "$out/dnsonly.pem" 4 get)"
stop_server
checks=$((checks + 3))
# want-read: the server is stopped while the ClientHello goes out, so the first handshake step cannot have an answer.
start_server good -tls1_3 -www
result=$(run host localhost "$out/good.pem" 6 silent "$server_pid")
[[ $result == 'result handshake wantRead='* && ${result#*wantRead=} -ge 1 ]] || { echo "tls-session (want-read): [$result]" >&2; exit 1; }
# want-write: a server that stopped reading fills the socket buffers.
result=$(run host localhost "$out/good.pem" 6 flood "$server_pid")
[[ $result == 'result flood wantWrite='* ]] || { echo "tls-session (flood): [$result]" >&2; exit 1; }
wants=${result#*wantWrite=}; wants=${wants%% *}
[[ $wants -ge 1 ]] || { echo "tls-session (flood): the session never said want-write: [$result]" >&2; exit 1; }
stop_server
checks=$((checks + 2))
echo "tls-session ok: $checks checks (modes none/chain/host, TLS 1.3 and 1.2, IP hosts, want-read, want-write)"
