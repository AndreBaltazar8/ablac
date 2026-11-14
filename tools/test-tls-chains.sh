#!/usr/bin/env bash
# The pure TLS client against `openssl s_server` with certificate chains of the kind a provider sends: an RSA-2048 root,
# an intermediate and a leaf (and the same in ECDSA P-256), TLS 1.3 and TLS 1.2, the intermediate sent after the leaf, the
# chain sent out of order (root before the intermediate), no intermediate at all (refused), another host name (refused),
# a trust store that does not hold the root (refused), a leaf that is not for TLS server use (refused),
# and the root given inside a bundle. Usage: tools/test-tls-chains.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
. "$root/tools/lib/openssl-server.sh"
out=build/tls-chains
rm -rf "$out"
mkdir -p "$out"
command -v openssl > /dev/null || { echo 'tls-chains: no openssl; skipped'; exit 0; }
"$compiler" build tests/cases/tls-pure/handles.ab -o "$out/handles" --fast --no-cache

make_chain() { # kind: rsa | ec
    local kind=$1 key_args
    if [[ $kind == rsa ]]; then key_args=(-newkey rsa:2048); else key_args=(-newkey ec -pkeyopt ec_paramgen_curve:P-256); fi
    openssl req -x509 "${key_args[@]}" -nodes -keyout "$out/$kind-root.key" -out "$out/$kind-root.pem" -subj "/CN=$kind root" -days 2 \
        -addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign 2> /dev/null
    printf 'basicConstraints=critical,CA:TRUE,pathlen:0\nkeyUsage=critical,keyCertSign\n' > "$out/$kind-inter.ext"
    openssl req -new "${key_args[@]}" -nodes -keyout "$out/$kind-inter.key" -out "$out/$kind-inter.csr" -subj "/CN=$kind intermediate" 2> /dev/null
    openssl x509 -req -in "$out/$kind-inter.csr" -CA "$out/$kind-root.pem" -CAkey "$out/$kind-root.key" -CAcreateserial \
        -extfile "$out/$kind-inter.ext" -out "$out/$kind-inter.pem" -days 2 2> /dev/null
    printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost\n' > "$out/$kind-leaf.ext"
    openssl req -new "${key_args[@]}" -nodes -keyout "$out/$kind-leaf.key" -out "$out/$kind-leaf.csr" -subj /CN=localhost 2> /dev/null
    openssl x509 -req -in "$out/$kind-leaf.csr" -CA "$out/$kind-inter.pem" -CAkey "$out/$kind-inter.key" -CAcreateserial \
        -extfile "$out/$kind-leaf.ext" -out "$out/$kind-leaf.pem" -days 2 2> /dev/null
    # A leaf for client authentication only.
    printf 'basicConstraints=critical,CA:FALSE\nextendedKeyUsage=clientAuth\nsubjectAltName=DNS:localhost\n' > "$out/$kind-client.ext"
    openssl x509 -req -in "$out/$kind-leaf.csr" -CA "$out/$kind-inter.pem" -CAkey "$out/$kind-inter.key" -CAcreateserial \
        -extfile "$out/$kind-client.ext" -out "$out/$kind-clientonly.pem" -days 2 2> /dev/null
    cat "$out/$kind-root.pem" "$out/$kind-inter.pem" > "$out/$kind-outoforder.pem"
}
make_chain rsa
make_chain ec
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$out/other.key" -out "$out/other.pem" -subj "/CN=other root" -days 2 2> /dev/null

server_pid=
trap '[[ -z $server_pid ]] || kill "$server_pid" 2> /dev/null || true' EXIT
# serve LEAF KEY TLSFLAG [s_server options...]: starts s_server on a free port ($port)
serve() {
    local leaf=$1 key=$2 flag=$3
    shift 3
    # (Dual-stack, kernel-chosen port: the host-name check connects to 127.0.0.1, the others to localhost.)
    openssl_server_start "$out/server.log" 0 -cert "$leaf" -key "$key" "$flag" -www "$@" || { echo "tls-chains: s_server did not start" >&2; exit 1; }
    port=$openssl_server_port
    server_pid=$openssl_server_pid
}
stop() { kill "$server_pid" 2> /dev/null || true; wait "$server_pid" 2> /dev/null || true; server_pid=; }
expect_ok() { # description, host, ca
    local result
    result=$("$out/handles" get "$2" "$port" "$3" 2>&1) || { echo "tls-chains: $1: $result" >&2; openssl_server_show "$port"; exit 1; }
}
expect_refused() { # description, host, ca, text the reason holds
    local result
    result=$("$out/handles" refuse "$2" "$port" "$3" 2>&1) || { echo "tls-chains: $1 was not refused: $result" >&2; openssl_server_show "$port"; exit 1; }
    [[ $result == *"$4"* ]] || { echo "tls-chains: $1: refused with '$result', wanted '$4'" >&2; openssl_server_show "$port"; exit 1; }
}

for kind in rsa ec; do
    for flag in -tls1_3 -tls1_2; do
        serve "$out/$kind-leaf.pem" "$out/$kind-leaf.key" "$flag" -cert_chain "$out/$kind-inter.pem"
        expect_ok "$kind $flag chain" localhost "$out/$kind-root.pem"
        # The same trust store given as a bundle with the roots of other providers in front.
        cat "$out/other.pem" "$out/$kind-root.pem" > "$out/bundle.pem"
        expect_ok "$kind $flag chain, root in a bundle" localhost "$out/bundle.pem"
        expect_refused "$kind $flag, host name" 127.0.0.1 "$out/$kind-root.pem" 'not valid for the host name'
        expect_refused "$kind $flag, untrusted root" localhost "$out/other.pem" 'unknown authority'
        stop
        serve "$out/$kind-leaf.pem" "$out/$kind-leaf.key" "$flag" -cert_chain "$out/$kind-outoforder.pem"
        expect_ok "$kind $flag chain sent root first" localhost "$out/$kind-root.pem"
        stop
        serve "$out/$kind-leaf.pem" "$out/$kind-leaf.key" "$flag"
        expect_refused "$kind $flag, no intermediate sent" localhost "$out/$kind-root.pem" 'unknown authority'
        stop
        serve "$out/$kind-clientonly.pem" "$out/$kind-leaf.key" "$flag" -cert_chain "$out/$kind-inter.pem"
        expect_refused "$kind $flag, client-only leaf" localhost "$out/$kind-root.pem" 'purpose'
        stop
        echo "ok   $kind chain, $flag: root and intermediate, out of order, bundle; refused: wrong host, untrusted root, no intermediate, client-only leaf"
    done
done
