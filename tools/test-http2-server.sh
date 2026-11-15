#!/usr/bin/env bash
# The HTTP/2 server (abla/http/h2/server and abla/http/event/tls's HttpsEventServer) against independent peers, with tools/h2spec/server.ab as the server under test:
#   h2spec 2.6.0 (generic, HPACK and RFC 9113 groups, strict mode: every test must pass) over TLS with ALPN, and over h2c on an HTTP/2-only port;
#   our H2Client through HttpAsyncClient (tests/cases/http2/net.ab: 30 concurrent requests on one connection, a 3 MiB download, a 300 KB upload, HEAD);
#   curl (ALPN picks h2 or http/1.1), nghttp (client) and h2load (20000 requests, 8 connections, 100 streams each) against the TLS port;
#   the attacks of tests/cases/http2/attack.ab (Rapid Reset, a CONTINUATION flood, PING and SETTINGS floods, an oversized frame, unfinished streams) over a socket, with the server
#   still answering after each; and the HTTP/1.1 and h2c prior-knowledge paths of a plain port.
# Usage: tools/test-http2-server.sh [compiler]. Needs openssl, h2spec, nghttp, h2load and curl (nix-shell provides them).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/http2-server
rm -rf "$out"
mkdir -p "$out"
for tool in openssl h2spec nghttp h2load curl; do
    command -v "$tool" > /dev/null || { echo "http2 server: $tool is needed (nix-shell provides it)" >&2; exit 1; }
done
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/p256.key" 2> /dev/null
openssl req -x509 -new -key "$out/p256.key" -out "$out/p256.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' -days 2 2> /dev/null

for program in server:tools/h2spec/server.ab attack:tests/cases/http2/attack.ab net:tests/cases/http2/net.ab; do
    name=${program%%:*}
    "$compiler" build "${program#*:}" -o "$out/$name" --no-cache > "$out/$name.build.log" 2>&1 || { cat "$out/$name.build.log" >&2; exit 1; }
done

pids=()
trap 'for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done' EXIT
start_server() {   # start_server NAME ARGS...: runs the server, sets $port from its "listening" line
    local name=$1
    shift
    "$out/server" 0 "$@" > "$out/$name.log" 2>&1 &
    pids+=("$!")
    for _ in $(seq 100); do
        port=$(sed -n 's/^listening //p' "$out/$name.log" | head -1)
        [[ -n $port ]] && return 0
        sleep 0.1
    done
    echo "http2 server: $name did not start: $(head -3 "$out/$name.log")" >&2
    exit 1
}

check_h2spec() {   # check_h2spec LABEL ARGS...
    local label=$1
    shift
    h2spec "$@" --strict -o 5 > "$out/h2spec-$label.log" 2>&1 || true
    local summary
    summary=$(grep -E '^[0-9]+ tests, ' "$out/h2spec-$label.log" | tail -1)
    [[ $summary == *' 0 failed'* && $summary == *' 0 skipped'* ]] || { grep -B1 -A8 '×' "$out/h2spec-$label.log" | head -40 >&2; echo "http2 server: h2spec ($label): $summary" >&2; exit 1; }
    echo "h2spec ($label): $summary"
}

start_server tls "$root/$out/p256.pem" "$root/$out/p256.key"
tls_port=$port
check_h2spec tls -h localhost -p "$tls_port" -t -k

start_server h2c h2only
h2c_port=$port
check_h2spec h2c -h 127.0.0.1 -p "$h2c_port"

start_server plain
plain_port=$port

# Our client over HTTPS.
result=$("$root/tools/run-limited.sh" "$out/net" "$tls_port" "$out/p256.pem" h2 3145728) || { echo "http2 server: our client: $result" >&2; exit 1; }
[[ $result == 'http2 net h2 ok' ]] || { echo "http2 server: our client: $result" >&2; exit 1; }
echo "our H2Client against the server over TLS ok"

# curl: ALPN decides.
v2=$(curl -sS --cacert "$out/p256.pem" --http2 -o "$out/curl2.body" -w '%{http_version}' "https://localhost:$tls_port/x")
v1=$(curl -sS --cacert "$out/p256.pem" --http1.1 -o "$out/curl1.body" -w '%{http_version}' "https://localhost:$tls_port/x")
[[ $v2 == 2 && $v1 == 1.1 ]] || { echo "http2 server: curl got HTTP version '$v2' with --http2 and '$v1' with --http1.1" >&2; exit 1; }
[[ $(cat "$out/curl2.body") == 'hello h2' && $(cat "$out/curl1.body") == 'hello h2' ]] || { echo "http2 server: curl bodies differ" >&2; exit 1; }
post=$(curl -sS --cacert "$out/p256.pem" --http2 --data-binary 'posted body' "https://localhost:$tls_port/echo")
[[ $post == 'posted body' ]] || { echo "http2 server: POST /echo over h2 returned '$post'" >&2; exit 1; }
# The plain port: HTTP/1.1, and h2c with prior knowledge.
[[ $(curl -sS --http1.1 -o /dev/null -w '%{http_version}' "http://127.0.0.1:$plain_port/x") == 1.1 ]] || { echo "http2 server: plain HTTP/1.1 failed" >&2; exit 1; }
[[ $(curl -sS --http2-prior-knowledge -o /dev/null -w '%{http_version}' "http://127.0.0.1:$plain_port/x") == 2 ]] || { echo "http2 server: h2c prior knowledge failed" >&2; exit 1; }
echo "curl: h2 and http/1.1 over TLS, POST, and a plain port with HTTP/1.1 and h2c ok"

# nghttp: a 3 MiB response and a POST.
nghttp -n "https://localhost:$tls_port/big.bin" > "$out/nghttp.log" 2>&1 || { tail -5 "$out/nghttp.log" >&2; echo "http2 server: nghttp failed" >&2; exit 1; }
printf 'upload' > "$out/upload.txt"
nghttp -n -d "$out/upload.txt" "https://localhost:$tls_port/echo" > "$out/nghttp2.log" 2>&1 || { tail -5 "$out/nghttp2.log" >&2; echo "http2 server: nghttp POST failed" >&2; exit 1; }
echo "nghttp ok"

# h2load: 20000 requests over 8 connections, 100 streams each.
h2load -n 20000 -c 8 -m 100 "https://localhost:$tls_port/x" > "$out/h2load.log" 2>&1 || { tail -8 "$out/h2load.log" >&2; echo "http2 server: h2load failed" >&2; exit 1; }
grep -q ' 0 failed, 0 errored, 0 timeout' "$out/h2load.log" || { tail -12 "$out/h2load.log" >&2; echo "http2 server: h2load saw failures" >&2; exit 1; }
echo "h2load: $(grep -E '^finished in' "$out/h2load.log")"

# The attacks, over a socket.
result=$("$root/tools/run-limited.sh" "$out/attack" "$h2c_port") || { echo "http2 server: attacks: $result" >&2; exit 1; }
[[ $result == 'http2 attack ok' ]] || { echo "http2 server: attacks: $result" >&2; exit 1; }
echo "attacks ok: the server answers after each"
echo "http2 server ok"
