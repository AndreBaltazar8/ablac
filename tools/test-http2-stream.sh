#!/usr/bin/env bash
# The streaming API of abla/http/async (tests/cases/http2/streamnet.ab) against h2o and nghttpd, over h2c and over TLS: a download of STREAM_BYTES (default 1 GiB, a sparse file served
# by h2o) read piece by piece, an upload of the same size written as writeBody takes it (nghttpd reads the body), and a consumer that stops reading. What it checks besides the bytes:
# an unread stream holds at most one stream window (262144 bytes) of the peer's data, writeBody tells a fast sender to wait, and the client process' resident memory stays far below the
# transfer (STREAM_RSS_LIMIT_KIB, default 131072: about twice what a transfer of any size peaked at, 70 MB at 256 MiB and beyond). The TLS runs use STREAM_TLS_BYTES (default 64 MiB): the pure-Abla cipher is not the thing under test.
# Then the same over HTTP/1.1 (a sink server counts the upload). Usage: tools/test-http2-stream.sh [compiler]. Needs openssl, h2o and nghttpd (nix-shell provides them).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
for tool in openssl h2o nghttpd; do
    command -v "$tool" > /dev/null || { echo "http2 stream: $tool is needed (nix-shell provides it)" >&2; exit 1; }
done
bytes=${STREAM_BYTES:-1073741824}
tls_bytes=${STREAM_TLS_BYTES:-67108864}
limit=${STREAM_RSS_LIMIT_KIB:-131072}
out=build/http2-stream
rm -rf "$out"
mkdir -p "$out/docroot" "$out/upload-root"
for program in streamnet sink; do
    "$compiler" build "tests/cases/http2/$program.ab" -o "$out/$program" --no-cache > "$out/$program.build.log" 2>&1 || { cat "$out/$program.build.log" >&2; exit 1; }
done
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/p256.key" 2> /dev/null
openssl req -x509 -new -key "$out/p256.key" -out "$out/p256.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost' -days 2 2> /dev/null
# A file of zero bytes the size of the biggest transfer: sparse, so it costs no disk.
slow_bytes=$((tls_bytes < 33554432 ? tls_bytes : 33554432))
truncate -s "$bytes" "$out/docroot/gig.bin"
truncate -s "$tls_bytes" "$out/docroot/tls.bin"
truncate -s "$slow_bytes" "$out/docroot/slow.bin"
printf 'sink\n' > "$out/upload-root/sink.txt"

pids=()
cleanup() {
    for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done
}
trap cleanup EXIT
free_port() {
    local candidate
    for _ in $(seq 100); do
        candidate=$((20000 + RANDOM % 10000))
        (exec 3<> "/dev/tcp/127.0.0.1/$candidate") 2> /dev/null || { echo "$candidate"; return 0; }
    done
    return 1
}
wait_listening() {   # wait_listening PORT PID LOG
    for _ in $(seq 600); do
        (exec 3<> "/dev/tcp/127.0.0.1/$1") 2> /dev/null && return 0
        kill -0 "$2" 2> /dev/null || break
        sleep 0.1
    done
    echo "http2 stream: a server on port $1 did not start: $(head -3 "$3")" >&2
    exit 1
}

h2o_tls=$(free_port)
h2o_plain=$(free_port)
cat > "$out/h2o.conf" << EOF
listen:
  port: $h2o_tls
  ssl:
    certificate-file: $root/$out/p256.pem
    key-file: $root/$out/p256.key
listen:
  port: $h2o_plain
hosts:
  default:
    paths:
      /:
        file.dir: $root/$out/docroot
EOF
h2o -c "$out/h2o.conf" > "$out/h2o.log" 2>&1 &
pids+=("$!")
wait_listening "$h2o_plain" "${pids[-1]}" "$out/h2o.log"
wait_listening "$h2o_tls" "${pids[-1]}" "$out/h2o.log"
sink_plain=$(free_port)
nghttpd --no-tls -d "$out/upload-root" "$sink_plain" > "$out/nghttpd-plain.log" 2>&1 &
pids+=("$!")
wait_listening "$sink_plain" "${pids[-1]}" "$out/nghttpd-plain.log"
sink_tls=$(free_port)
nghttpd -d "$out/upload-root" "$sink_tls" "$out/p256.key" "$out/p256.pem" > "$out/nghttpd-tls.log" 2>&1 &
pids+=("$!")
wait_listening "$sink_tls" "${pids[-1]}" "$out/nghttpd-tls.log"

run() {   # run LABEL PORT CA MODE BYTES PATH [h1]
    local label=$1 result peak
    result=$("$root/tools/run-limited.sh" "$out/streamnet" "$2" "$3" "$4" "$5" "$6" ${7:-}) || { echo "http2 stream ($label): $result" >&2; exit 1; }
    [[ $result == "http2 streamnet $4 ok"* ]] || { echo "http2 stream ($label): $result" >&2; exit 1; }
    peak=${result##*peak resident }
    peak=${peak%% KiB*}
    (( peak < limit )) || { echo "http2 stream ($label): peak resident memory $peak KiB for a transfer of $5 bytes, over the limit of $limit KiB" >&2; exit 1; }
    echo "http2 stream ($label): $result"
}
run "download over h2c" "$h2o_plain" - down "$bytes" /gig.bin
run "upload over h2c" "$sink_plain" - up "$bytes" /sink.txt
run "download over TLS" "$h2o_tls" "$out/p256.pem" down "$tls_bytes" /tls.bin
run "upload over TLS" "$sink_tls" "$out/p256.pem" up "$tls_bytes" /sink.txt

run "a consumer that stops reading, h2c" "$h2o_plain" - slow "$slow_bytes" /slow.bin
# The same over HTTP/1.1 (the clients offer no h2, h2o answers HTTP/1.1): reading stops while 192 KiB wait, bodies are Content-Length, chunked, and written as writeBody takes them.
# The upload goes to a sink that counts what it was sent (tests/cases/http2/sink.ab) and says so; the client checks the count.
sink_port=$(free_port)
"$out/sink" "$sink_port" > "$out/sink.log" 2>&1 &
pids+=("$!")
wait_listening "$sink_port" "${pids[-1]}" "$out/sink.log"
run "download over HTTP/1.1" "$h2o_plain" - down "$bytes" /gig.bin h1
run "download over TLS, HTTP/1.1" "$h2o_tls" "$out/p256.pem" down "$tls_bytes" /tls.bin h1
run "upload over HTTP/1.1, known length" "$sink_port" - up "$bytes" /sink h1
run "upload over HTTP/1.1, chunked" "$sink_port" - upchunked "$bytes" /sink h1
run "a consumer that stops reading, HTTP/1.1" "$h2o_plain" - slow "$slow_bytes" /slow.bin h1
echo "http2 stream ok"
