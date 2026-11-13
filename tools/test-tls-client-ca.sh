#!/usr/bin/env bash
# #822: tlsListenWithClientCa against `openssl s_client` (TLS 1.3 and 1.2): a client certificate from the listener's
# CA is accepted and the connection reports it (peerCertificate, peerChain, peerCertificateVerified); a client with none,
# one from another CA and one without the client-authentication usage are refused; with `required` false a client with
# none is accepted (and not verified), and one from another CA is still refused. Needs openssl.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/tls-client-ca
rm -rf "$out"
mkdir -p "$out"
if ! command -v openssl > /dev/null; then
    echo 'tls client CA: no openssl; skipped'
    exit 0
fi
ec() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2> /dev/null; }
authority() { # name
    ec "$out/$1.key"
    openssl req -x509 -new -key "$out/$1.key" -out "$out/$1.pem" -subj "/CN=$1" -days 2 \
        -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign 2> /dev/null
}
leaf() { # name authority usage
    ec "$out/$1.key"
    openssl req -new -key "$out/$1.key" -out "$out/$1.csr" -subj "/CN=$1" 2> /dev/null
    printf 'basicConstraints=CA:FALSE\nextendedKeyUsage=%s\n' "$3" > "$out/$1.ext"
    openssl x509 -req -in "$out/$1.csr" -CA "$out/$2.pem" -CAkey "$out/$2.key" -CAcreateserial -out "$out/$1.pem" -days 2 \
        -extfile "$out/$1.ext" 2> /dev/null
}
authority ca
authority other
leaf alice ca clientAuth
leaf mallory other clientAuth
leaf serveronly ca serverAuth
ec "$out/server.key"
openssl req -x509 -new -key "$out/server.key" -out "$out/server.pem" -subj /CN=localhost -days 2 \
    -addext subjectAltName=DNS:localhost 2> /dev/null
"$compiler" build tests/cases/tls-pure/client-ca.ab -o "$out/server" --no-cache
server_pid=
trap '[[ -z $server_pid ]] || kill "$server_pid" 2> /dev/null || true' EXIT
start() { # required count: sets $port, $log
    log="$out/server-$1.log"
    "$out/server" "$out/server.pem" "$out/server.key" "$out/ca.pem" "$1" "$2" > "$log" 2>&1 &
    server_pid=$!
    for _ in $(seq 100); do
        grep -q '^port ' "$log" 2> /dev/null && break
        sleep 0.1
    done
    port=$(sed -n 's/^port //p' "$log")
    [[ -n $port ]] || { cat "$log" >&2; echo 'tls client CA: the server did not listen' >&2; exit 1; }
}
connect() { # version certificate-name-or-none
    local arguments=(-connect "127.0.0.1:$port" "-$1")
    [[ $2 == none ]] || arguments+=(-cert "$out/$2.pem" -key "$out/$2.key")
    timeout 15 openssl s_client "${arguments[@]}" < /dev/null > "$out/client.log" 2>&1 || true
}
expect() { # log line-number expected
    local line
    line=$(sed -n "$(( $2 + 1 ))p" "$1")
    [[ $line == "$3" ]] || { cat "$1" >&2; echo "tls client CA: connection $2 said '$line', expected '$3'" >&2; exit 1; }
}
# Required.
start 1 5
connect tls1_3 alice
connect tls1_2 alice
connect tls1_3 none
connect tls1_3 mallory
connect tls1_3 serveronly
wait "$server_pid" || true
server_pid=
expect "$log" 1 'accepted true verified true chain 1 cn alice'
expect "$log" 2 'accepted true verified true chain 1 cn alice'
expect "$log" 3 'accepted false verified false chain 0 cn '
expect "$log" 4 'accepted false verified false chain 1 cn mallory'
expect "$log" 5 'accepted false verified false chain 1 cn serveronly'
# Optional.
start 0 2
connect tls1_3 none
connect tls1_3 mallory
wait "$server_pid" || true
server_pid=
expect "$log" 1 'accepted true verified false chain 0 cn '
expect "$log" 2 'accepted false verified false chain 1 cn mallory'
echo 'tls client CA: a good certificate is reported, the others refused (TLS 1.3 and 1.2, required and optional)'
