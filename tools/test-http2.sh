#!/usr/bin/env bash
# HTTP/2 for abla/http/async (abla/http/h2): the HPACK test (RFC 7541 appendix C, the Huffman code, the decoder's limits, the encoder's never-indexed rule), the H2Client
# test against a scripted peer (flow control, floods, limits, response rules), the async client against a scripted h2c server in a forked child (per-stream timeout, REFUSED_STREAM and GOAWAY retries, a protocol error, trailers, PING before reuse, idle close), then the real thing: HttpAsyncClient with http2 on against `nghttpd` (nghttp2, over TLS with ALPN: 30
# concurrent requests on one connection, a 3 MiB download and a 300 KB upload across the flow-control windows, HEAD, a second wave on the same connection), the ALPN fallback to
# HTTP/1.1 against `openssl s_server`, and the default options (http2 on: h2 against nghttpd, HTTP/1.1 against s_server; http2 = false against h2o in test-http2-h2o.sh). `h2load` then drives 20000 requests over 8 connections at nghttpd, 100 streams each, through the
# same server for a load run of the server side only (it checks nghttpd, not us). Usage: tools/test-http2.sh [compiler]
# Needs openssl and nghttpd (nix-shell provides both); without nghttpd the scripted tests run and the network part says so and fails.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
. "$root/tools/lib/openssl-server.sh"
out=build/http2
rm -rf "$out"
mkdir -p "$out/docroot"

for name in hpack client stream server mock; do
    "$compiler" build "tests/cases/http2/$name.ab" -o "$out/$name" --no-cache > "$out/$name.build.log" 2>&1 || { cat "$out/$name.build.log" >&2; exit 1; }
    result=$("$root/tools/run-limited.sh" "$out/$name") || { echo "http2 $name: $result" >&2; exit 1; }
    [[ $result == "http2 $name ok" ]] || { echo "http2 $name: $result" >&2; exit 1; }
    echo "http2 $name ok"
done

"$compiler" build tests/cases/http2/hpack-corpus.ab -o "$out/hpack-corpus" --no-cache > "$out/hpack-corpus.build.log" 2>&1 || { cat "$out/hpack-corpus.build.log" >&2; exit 1; }
result=$("$root/tools/run-limited.sh" "$out/hpack-corpus" "$root/tests/vectors/hpack/stories.txt") || { echo "http2 hpack-corpus: $result" >&2; exit 1; }
echo "$result"

command -v openssl > /dev/null || { echo "http2: openssl is needed for the network tests" >&2; exit 1; }
command -v nghttpd > /dev/null || { echo "http2: nghttpd (nghttp2) is needed for the network tests; the scripted tests above passed" >&2; exit 1; }
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/p256.key" 2> /dev/null
openssl req -x509 -new -key "$out/p256.key" -out "$out/p256.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost' -days 2 2> /dev/null
printf 'hello h2\n' > "$out/docroot/small.txt"
head -c 3145728 /dev/urandom > "$out/docroot/big.bin"

nghttpd_pid=
trap '[[ -z $nghttpd_pid ]] || kill "$nghttpd_pid" 2> /dev/null || true; [[ -z $openssl_server_pid ]] || kill "$openssl_server_pid" 2> /dev/null || true' EXIT

# nghttpd takes a port number: one below the ephemeral range that nobody listens on (retried when it fails to bind).
nghttpd_port=
for attempt in $(seq 20); do
    candidate=$((20000 + RANDOM % 10000))
    ss -ltn "sport = :$candidate" 2> /dev/null | grep LISTEN > /dev/null && continue
    nghttpd -d "$out/docroot" "$candidate" "$out/p256.key" "$out/p256.pem" > "$out/nghttpd.log" 2>&1 &
    nghttpd_pid=$!
    for _ in $(seq 600); do
        ss -ltn "sport = :$candidate" 2> /dev/null | grep LISTEN > /dev/null && { nghttpd_port=$candidate; break; }
        kill -0 "$nghttpd_pid" 2> /dev/null || break
        sleep 0.1
    done
    [[ -n $nghttpd_port ]] && break
    kill "$nghttpd_pid" 2> /dev/null || true
    nghttpd_pid=
done
[[ -n $nghttpd_port ]] || { echo "http2: nghttpd did not start: $(head -3 "$out/nghttpd.log")" >&2; exit 1; }

"$compiler" build tests/cases/http2/net.ab -o "$out/net" --no-cache > "$out/net.build.log" 2>&1 || { cat "$out/net.build.log" >&2; exit 1; }
result=$("$root/tools/run-limited.sh" "$out/net" "$nghttpd_port" "$out/p256.pem" h2 3145728) || { echo "http2 net h2: $result" >&2; tail -5 "$out/nghttpd.log" >&2; exit 1; }
[[ $result == 'http2 net h2 ok' ]] || { echo "http2 net h2: $result" >&2; exit 1; }
echo "http2 net h2 ok (nghttpd)"

for mode in default-h2; do
    result=$("$root/tools/run-limited.sh" "$out/net" "$nghttpd_port" "$out/p256.pem" "$mode") || { echo "http2 net $mode: $result" >&2; tail -5 "$out/nghttpd.log" >&2; exit 1; }
    [[ $result == "http2 net $mode ok" ]] || { echo "http2 net $mode: $result" >&2; exit 1; }
    echo "http2 net $mode ok (nghttpd)"
done

if command -v h2load > /dev/null; then
    h2load -n 20000 -c 8 -m 100 "https://localhost:$nghttpd_port/small.txt" > "$out/h2load.log" 2>&1 || { tail -5 "$out/h2load.log" >&2; echo "http2: h2load failed" >&2; exit 1; }
    grep -q ' 0 failed, 0 errored, 0 timeout' "$out/h2load.log" || { tail -12 "$out/h2load.log" >&2; echo "http2: h2load saw failures" >&2; exit 1; }
    echo "http2 h2load ok (the server under 20000 requests)"
fi

# The ALPN fallback and the default options against a server that offers no h2.
for mode in fallback default; do
    openssl_server_start "$out/s_server.log" "0" -cert "$root/$out/p256.pem" -key "$root/$out/p256.key" -www || { echo "http2: s_server did not start" >&2; exit 1; }
    result=$("$root/tools/run-limited.sh" "$out/net" "$openssl_server_port" "$out/p256.pem" "$mode") || { echo "http2 net $mode: $result" >&2; exit 1; }
    [[ $result == "http2 net $mode ok" ]] || { echo "http2 net $mode: $result" >&2; exit 1; }
    kill "$openssl_server_pid" 2> /dev/null || true
    wait "$openssl_server_pid" 2> /dev/null || true
    openssl_server_pid=
    echo "http2 net $mode ok (openssl s_server)"
done
echo "http2 ok"
