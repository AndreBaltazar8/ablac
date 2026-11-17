#!/usr/bin/env bash
# HTTP/2 against h2o, a second implementation besides nghttp2 (tools/test-http2.sh, tools/test-http2-server.sh):
#   our client (tests/cases/http2/h2o.ab) against h2o over TLS with ALPN and over h2c with prior knowledge: 30 requests on one connection, a 3 MiB download of random bytes
#   compared with the file, HEAD, uploads of 300 KB and 3 MiB echoed back byte for byte (flow control both ways), a second wave on the same connection, and h2o's GOAWAY
#   (SIGTERM while a response is in flight: the response still arrives, a later request fails and does not hang);
#   h2o's own client (h2o-httpclient) against our server (tools/h2spec/server.ab) over TLS and h2c: many requests, a 3 MiB download compared with the server's pattern, a 3 MiB
#   upload echoed back, concurrent streams on one connection.
# Trailers are not covered here: h2o drops them when it proxies (checked: nghttpd --trailer through h2o loses them), so a trailer test through h2o would test h2o.
# They are covered against nghttpd (tools/test-http2.sh) and in process. (Seen once while this test was written: h2o-httpclient crashes with SIGSEGV when the server answers 413
# to an upload it is still sending; that is the client, so the uploads here stay inside the server's body limit.) Usage: tools/test-http2-h2o.sh [compiler]. Needs openssl, h2o and h2o-httpclient (nix-shell provides them).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
for tool in openssl h2o h2o-httpclient; do
    command -v "$tool" > /dev/null || { echo "http2 h2o: $tool is needed (nix-shell provides it)" >&2; exit 1; }
done
out=build/http2-h2o
rm -rf "$out"
mkdir -p "$out/docroot"
for program in h2o:tests/cases/http2/h2o.ab server:tools/h2spec/server.ab; do
    "$compiler" build "${program#*:}" -o "$out/${program%%:*}" --no-cache > "$out/${program%%:*}.build.log" 2>&1 || { cat "$out/${program%%:*}.build.log" >&2; exit 1; }
done
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/p256.key" 2> /dev/null
openssl req -x509 -new -key "$out/p256.key" -out "$out/p256.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost' -days 2 2> /dev/null
printf 'hello h2\n' > "$out/docroot/small.txt"
head -c 3145728 /dev/urandom > "$out/docroot/big.bin"

h2o_pid=
server_pid=
cleanup() {
    [[ -z $h2o_pid ]] || kill "$h2o_pid" 2> /dev/null || true
    [[ -z $server_pid ]] || kill "$server_pid" 2> /dev/null || true
}
trap cleanup EXIT

free_port() {   # a port below the ephemeral range that nobody listens on
    local candidate
    for _ in $(seq 50); do
        candidate=$((20000 + RANDOM % 10000))
        ss -ltn "sport = :$candidate" 2> /dev/null | grep LISTEN > /dev/null || { echo "$candidate"; return 0; }
    done
    return 1
}

# h2o on a TLS port and a plain one (HTTP/2 over cleartext needs no setup on h2o's side): /small.txt and /big.bin from the docroot, /echo (mruby: the request body back), /slow (2 s).
start_h2o() {
    tls_port=$(free_port)
    plain_port=$(free_port)
    cat > "$out/h2o.conf" << EOF
listen:
  port: $tls_port
  ssl:
    certificate-file: $root/$out/p256.pem
    key-file: $root/$out/p256.key
listen:
  port: $plain_port
http2-graceful-shutdown-timeout: 10
hosts:
  default:
    paths:
      /:
        file.dir: $root/$out/docroot
      /echo:
        mruby.handler: |
          Proc.new do |env|
            [200, {"content-type" => "application/octet-stream"}, [env["rack.input"].read]]
          end
      /slow:
        mruby.handler: |
          Proc.new do |env|
            sleep 2
            [200, {"content-type" => "text/plain"}, ["slow\n"]]
          end
EOF
    h2o -c "$out/h2o.conf" > "$out/h2o.log" 2>&1 &
    h2o_pid=$!
    for _ in $(seq 100); do
        ss -ltn "sport = :$tls_port" 2> /dev/null | grep LISTEN > /dev/null && ss -ltn "sport = :$plain_port" 2> /dev/null | grep LISTEN > /dev/null && return 0
        kill -0 "$h2o_pid" 2> /dev/null || break
        sleep 0.1
    done
    echo "http2 h2o: h2o did not start: $(head -5 "$out/h2o.log")" >&2
    exit 1
}
stop_h2o() {
    kill "$h2o_pid" 2> /dev/null || true
    wait "$h2o_pid" 2> /dev/null || true
    h2o_pid=
}

# Our client against h2o.
run_client() {   # run_client LABEL ARGS...
    local label=$1 result
    shift
    result=$("$root/tools/run-limited.sh" "$out/h2o" "$@") || { echo "http2 h2o ($label): $result" >&2; head -5 "$out/h2o.log" >&2; exit 1; }
    [[ $result == "http2 h2o ${*: -2:1} ok" ]] || { echo "http2 h2o ($label): $result" >&2; exit 1; }
    echo "http2 h2o ($label) ok"
}
start_h2o
run_client "client over TLS" "$tls_port" "$out/p256.pem" full "$out/docroot"
run_client "client over h2c" "$plain_port" - full "$out/docroot"
stop_h2o
for transport in tls plain; do
    start_h2o
    if [[ $transport == tls ]]; then port=$tls_port; ca=$out/p256.pem; else port=$plain_port; ca=-; fi
    "$root/tools/run-limited.sh" "$out/h2o" "$port" "$ca" goaway "$out/docroot" > "$out/goaway.out" 2>&1 &
    client_pid=$!
    for _ in $(seq 100); do grep -q '^sent' "$out/goaway.out" 2> /dev/null && break; sleep 0.1; done
    grep -q '^sent' "$out/goaway.out" || { cat "$out/goaway.out" >&2; echo "http2 h2o: the client never sent the slow request" >&2; exit 1; }
    sleep 0.3
    kill -TERM "$h2o_pid"
    wait "$client_pid" || { cat "$out/goaway.out" >&2; echo "http2 h2o (GOAWAY, $transport): the client failed" >&2; exit 1; }
    grep -q '^http2 h2o goaway ok' "$out/goaway.out" || { cat "$out/goaway.out" >&2; echo "http2 h2o (GOAWAY, $transport)" >&2; exit 1; }
    wait "$h2o_pid" 2> /dev/null || true
    h2o_pid=
    echo "http2 h2o (GOAWAY over $transport) ok"
done


# h2o's client against our server over TLS (h2o-httpclient does not speak HTTP/2 over cleartext: with an http:// URL it uses HTTP/1.1, so h2c is covered from the other side, above). 127.0.0.1,
# not localhost: the server listens on IPv4 and h2o-httpclient does not fall back from ::1 once it has several connections to open.
server_port=$(free_port)
"$out/server" "$server_port" "$out/p256.pem" "$out/p256.key" bigbody > "$out/server.log" 2>&1 &
server_pid=$!
for _ in $(seq 100); do grep -q '^listening' "$out/server.log" 2> /dev/null && break; sleep 0.1; done
grep -q '^listening' "$out/server.log" || { echo "http2 h2o: our server did not start: $(head -3 "$out/server.log")" >&2; exit 1; }
url=https://127.0.0.1:$server_port
hc() { timeout 120 h2o-httpclient -k -2 100 "$@"; }   # the exit status is the client's: non-zero on any I/O or protocol error
hc "$url/" > "$out/hc-get.out" 2>&1 || { cat "$out/hc-get.out" >&2; echo "http2 h2o (h2o-httpclient GET): failed" >&2; exit 1; }
grep -q '^HTTP/2 200' "$out/hc-get.out" && grep -q 'hello h2' "$out/hc-get.out" || { cat "$out/hc-get.out" >&2; echo "http2 h2o (h2o-httpclient GET): not an HTTP/2 200 with the body" >&2; exit 1; }
hc -t 2000 -C 50 -f -o /dev/null "$url/" > "$out/hc-many.out" 2>&1 || { tail -5 "$out/hc-many.out" >&2; echo "http2 h2o (h2o-httpclient, 2000 requests, 50 at once): failed" >&2; exit 1; }
unit=$(printf '0123456789abcdef%.0s' $(seq 64))
for _ in $(seq 3072); do printf '%s' "$unit"; done > "$out/pattern.bin"
hc -o "$out/big.out" "$url/big.bin" > "$out/hc-big.log" 2>&1 || { cat "$out/hc-big.log" >&2; echo "http2 h2o (h2o-httpclient, 3 MiB download): failed" >&2; exit 1; }
cmp -s "$out/big.out" "$out/pattern.bin" || { echo "http2 h2o (h2o-httpclient, 3 MiB download): the bytes differ from the server's pattern ($(stat -c %s "$out/big.out") of 3145728)" >&2; exit 1; }
head -c 3145728 /dev/zero | tr '\0' a > "$out/aaa.bin"
hc -m POST -b 3145728 -c 16384 -o "$out/post.out" "$url/echo" > "$out/hc-post.log" 2>&1 || { cat "$out/hc-post.log" >&2; echo "http2 h2o (h2o-httpclient, 3 MiB upload): failed" >&2; exit 1; }
cmp -s "$out/post.out" "$out/aaa.bin" || { echo "http2 h2o (h2o-httpclient, 3 MiB upload): the echo differs ($(stat -c %s "$out/post.out") of 3145728)" >&2; exit 1; }
# A body in tiny pieces (a DATA frame per byte or so) and several large uploads at once, each over its own connection.
hc -m POST -b 4000 -c 1 -o "$out/tiny.out" "$url/echo" > "$out/hc-tiny.log" 2>&1 || { cat "$out/hc-tiny.log" >&2; echo "http2 h2o (h2o-httpclient, 4000 one-byte pieces): failed" >&2; exit 1; }
[[ $(stat -c %s "$out/tiny.out") == 4000 ]] || { echo "http2 h2o (h2o-httpclient, one-byte pieces): $(stat -c %s "$out/tiny.out") of 4000 bytes came back" >&2; exit 1; }
hc -m POST -b 1048576 -c 4096 -t 20 -C 10 -o /dev/null "$url/echo" > "$out/hc-par.log" 2>&1 || { tail -5 "$out/hc-par.log" >&2; echo "http2 h2o (h2o-httpclient, 20 uploads of 1 MiB, 10 at once): failed" >&2; exit 1; }
kill -0 "$server_pid" 2> /dev/null || { echo "http2 h2o: our server died during the h2o-httpclient runs" >&2; tail -5 "$out/server.log" >&2; exit 1; }
echo "http2 h2o (h2o-httpclient against our server) ok"
echo "http2 h2o ok"
