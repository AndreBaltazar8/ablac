#!/usr/bin/env bash
# The hosted (OpenSSL) TLS client and server (stdlib/abla/tls/hosted), against a local `openssl s_server` and `s_client` (#1139 area 9):
#   - a certificate for another name, or one with the name only as its subject's common name, is refused; one for the name asked for is accepted, by DNS name and by IP address (an IP address is matched
#     against IP SANs, never against a DNS SAN that spells the same text);
#   - TLS 1.0 and 1.1 are refused by the client and the server, also when the system's OpenSSL configuration lowers the minimum (OPENSSL_CONF with
#     MinProtocol = TLSv1 and SECLEVEL 0: a program that depends on the configuration's floor is one admin's file from accepting them);
#   - the hosted server takes no renegotiation from a client (each one is a full handshake a TLS 1.2 client can ask for again and again) and the hosted client
#     takes none from its server.
# Needs openssl.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/tls-hosted-verify
rm -rf "$out"
mkdir -p "$out"
command -v openssl > /dev/null || { echo 'tls hosted verify: no openssl; skipped'; exit 0; }
fail() { echo "tls hosted verify: $1" >&2; exit 1; }
pids=()
trap 'for p in "${pids[@]:-}"; do [[ -z $p ]] || kill "$p" 2> /dev/null || true; done' EXIT
ec() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2> /dev/null; }
ec "$out/ca.key"
openssl req -x509 -new -key "$out/ca.key" -out "$out/ca.pem" -subj '/CN=Test CA' -days 2 \
    -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign 2> /dev/null
leaf() { # name subjectAltName
    ec "$out/$1.key"
    openssl req -new -key "$out/$1.key" -out "$out/$1.csr" -subj "/CN=$1" 2> /dev/null
    printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n' > "$out/$1.ext"
    [[ -z $2 ]] || printf 'subjectAltName=%s\n' "$2" >> "$out/$1.ext"
    openssl x509 -req -in "$out/$1.csr" -CA "$out/ca.pem" -CAkey "$out/ca.key" -CAcreateserial -out "$out/$1.pem" -days 2 \
        -extfile "$out/$1.ext" 2> /dev/null
}
leaf good DNS:localhost
leaf wrong DNS:other.example
leaf ipsan IP:127.0.0.1
leaf dnsip DNS:127.0.0.1
leaf localhost ''   # the name only in the subject's common name
# The configuration of an administrator who lowered the floor.
cat > "$out/lowered.cnf" <<'CONF'
openssl_conf = default_conf
[default_conf]
ssl_conf = ssl_sect
[ssl_sect]
system_default = system_default_sect
[system_default_sect]
MinProtocol = TLSv1
CipherString = DEFAULT:@SECLEVEL=0
CONF
"$compiler" build tests/cases/tls-hosted-verify/client.ab -o "$out/client" --fast --no-cache > "$out/client.log" 2>&1 || { cat "$out/client.log" >&2; fail 'the client did not build'; }
"$compiler" build tests/cases/tls-hosted-verify/server.ab -o "$out/server" --fast --no-cache > "$out/server.log" 2>&1 || { cat "$out/server.log" >&2; fail 'the server did not build'; }
port=$(( 20000 + RANDOM % 20000 ))
next() { port=$((port + 1)); }
# openssl s_server <certificate> <extra arguments...> in the background on $port.
serve() {
    local name=$1; shift
    openssl s_server -accept "$port" -cert "$out/$name.pem" -key "$out/$name.key" -quiet "$@" > "$out/s.$port.log" 2>&1 < /dev/null &
    pids+=("$!")
    for _ in $(seq 1 600); do (echo > "/dev/tcp/127.0.0.1/$port") 2> /dev/null && return; sleep 0.1; done
    fail "s_server did not listen on $port"
}
# The client against $port: the word it prints.
client() { # host [environment name=value]
    env ${2:-X=} "$out/client" "$1" "$port" "$out/ca.pem" 2> /dev/null | head -n1 | cut -d' ' -f1
}
expect() { # description wanted got
    [[ $3 == "$2" ]] || fail "$1: wanted '$2', got '$3'"
}
serve good; expect 'a certificate for the name asked' connected "$(client localhost)"; next
serve wrong; expect 'a certificate for another name' refused "$(client localhost)"; next
serve ipsan; expect 'an IP address with an IP SAN' connected "$(client 127.0.0.1)"; next
serve dnsip; expect 'an IP address with a DNS SAN spelling it' refused "$(client 127.0.0.1)"; next
serve localhost; expect 'a certificate that has the name only as its subject common name' refused "$(client localhost)"; next
serve good -tls1_1 -cipher 'ALL:@SECLEVEL=0'; expect 'a TLS 1.1 server' refused "$(client localhost)"; next
serve good -tls1_1 -cipher 'ALL:@SECLEVEL=0'; expect 'a TLS 1.1 server with the floor lowered by the configuration' refused "$(client localhost OPENSSL_CONF=$out/lowered.cnf)"; next
serve good -tls1 -cipher 'ALL:@SECLEVEL=0'; expect 'a TLS 1.0 server with the floor lowered by the configuration' refused "$(client localhost OPENSSL_CONF=$out/lowered.cnf)"; next
serve good -tls1_2; expect 'a TLS 1.2 server' connected "$(client localhost)"; next
# The hosted server: listens on a port it chooses; the client is openssl s_client.
listen() { # environment ...: sets $port and $slog
    slog="$out/server.$port.out"
    env ${1:-X=} "$out/server" "$out/good.pem" "$out/good.key" > "$slog" 2> "$slog.err" < /dev/null &
    pids+=("$!")
    for _ in $(seq 1 600); do grep -q '^port ' "$slog" 2> /dev/null && break; sleep 0.1; done
    port=$(sed -n 's/^port //p' "$slog")
    [[ -n $port ]] || fail 'the hosted server did not listen'
}
sclient() { # version [environment]
    printf 'ping\n' | env ${2:-X=} timeout 15 openssl s_client -connect "127.0.0.1:$port" "-$1" -CAfile "$out/ca.pem" -verify_hostname localhost -ign_eof > "$out/sclient.log" 2>&1 || true
}
listen; sclient tls1_2; grep -q '^pong' "$out/sclient.log" || { cat "$out/sclient.log" >&2; fail 'the hosted server did not answer a TLS 1.2 client'; }
listen; sclient tls1_1 "OPENSSL_CONF=$out/lowered.cnf"
! grep -q '^pong' "$out/sclient.log" || fail 'the hosted server answered a TLS 1.1 client when the configuration lowered the floor'
# A client that renegotiates (s_client's R command): the hosted server does not take a second handshake. (OpenSSL 3 servers refuse it by default; the
# option the library sets matters for OpenSSL 1.1.1, which does not: this check holds on either.)
listen
(printf 'ping\n'; sleep 1; printf 'R\n'; sleep 2) | timeout 15 openssl s_client -connect "127.0.0.1:$port" -tls1_2 -CAfile "$out/ca.pem" > "$out/renegotiate.log" 2>&1 || true
grep -q 'no renegotiation' "$out/renegotiate.log" || { cat "$out/renegotiate.log" >&2; fail 'the hosted server took a renegotiation'; }
# A server that asks the hosted client to renegotiate (s_server's R command): the client refuses (no_renegotiation), so a server cannot change the
# session's parameters under a program that is not looking.
port=$((port + 1))
(sleep 3; printf 'R\n'; sleep 4) | openssl s_server -accept "$port" -cert "$out/good.pem" -key "$out/good.key" -tls1_2 > "$out/s.reneg.log" 2>&1 &
pids+=("$!")
for _ in $(seq 1 600); do (echo > "/dev/tcp/127.0.0.1/$port") 2> /dev/null && break; sleep 0.1; done
timeout 20 "$out/client" localhost "$port" "$out/ca.pem" linger > "$out/reneg-client.out" 2>&1 || true
grep -q 'no renegotiation' "$out/s.reneg.log" || { cat "$out/s.reneg.log" >&2; fail 'the hosted client renegotiated when its server asked'; }
echo "tls hosted verify: names and IP addresses are checked as such, TLS 1.0 and 1.1 are refused whatever the configuration says, and neither side takes a renegotiation"
