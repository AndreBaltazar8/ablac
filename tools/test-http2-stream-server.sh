#!/usr/bin/env bash
# Streaming routes of the HTTPS event server (tests/cases/http2/streamserver.ab: HttpsEventServer.streamRoute with HttpStreamHandler) against curl and our own streaming client
# (tests/cases/http2/streamnet.ab), over h2c and TLS (HTTP/2): small exchanges (server-sent events, an echo of 1.5 MB, a sink that counts, a download of a few MB, the body limit of a route:
# 413), then STREAM_BYTES (default 1 GiB) down, up and echoed at once, a consumer that stops reading, and a request body nobody takes (the stream stalls after one window and the server's idle timeout
# ends it). What it checks besides the bytes: the server's resident memory (its VmHWM, STREAM_SERVER_RSS_LIMIT_KIB, default 131072) stays flat through all of it, and so does the client's.
# Usage: tools/test-http2-stream-server.sh [compiler]. Needs openssl and curl (nix-shell provides them).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
for tool in openssl curl; do
    command -v "$tool" > /dev/null || { echo "http2 stream server: $tool is needed (nix-shell provides it)" >&2; exit 1; }
done
bytes=${STREAM_BYTES:-1073741824}
tls_bytes=${STREAM_TLS_BYTES:-67108864}
limit=${STREAM_SERVER_RSS_LIMIT_KIB:-131072}
client_limit=${STREAM_RSS_LIMIT_KIB:-131072}
out=build/http2-stream-server
rm -rf "$out"
mkdir -p "$out"
for program in streamserver streamnet; do
    "$compiler" build "tests/cases/http2/$program.ab" -o "$out/$program" --no-cache > "$out/$program.build.log" 2>&1 || { cat "$out/$program.build.log" >&2; exit 1; }
done
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/p256.key" 2> /dev/null
openssl req -x509 -new -key "$out/p256.key" -out "$out/p256.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' -days 2 2> /dev/null
head -c 1500000 /dev/urandom > "$out/body.bin"

pids=()
trap 'for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done' EXIT
free_port() {
    local candidate
    for _ in $(seq 100); do
        candidate=$((20000 + RANDOM % 10000))
        (exec 3<> "/dev/tcp/127.0.0.1/$candidate") 2> /dev/null || { echo "$candidate"; return 0; }
    done
    return 1
}
start_server() {   # start_server NAME ARGS...: sets $port, $server_pid
    local name=$1
    shift
    port=$(free_port)
    "$out/streamserver" "$port" "$@" > "$out/$name.log" 2>&1 &
    server_pid=$!
    pids+=("$server_pid")
    for _ in $(seq 100); do
        (exec 3<> "/dev/tcp/127.0.0.1/$port") 2> /dev/null && return 0
        kill -0 "$server_pid" 2> /dev/null || break
        sleep 0.1
    done
    echo "http2 stream server: $name did not start: $(head -3 "$out/$name.log")" >&2
    exit 1
}
start_server plain idle 2500
plain_port=$port
plain_pid=$server_pid
start_server tls "$root/$out/p256.pem" "$root/$out/p256.key" idle 2500
tls_port=$port
tls_pid=$server_pid

# curl, h2c and TLS: server-sent events, the buffered handler beside the streaming ones, an echo of 1.5 MB, a sink, a download, a route's body limit.
for target in "h2c --http2-prior-knowledge http://127.0.0.1:$plain_port" "TLS --http2 --cacert $out/p256.pem https://localhost:$tls_port"; do
    label=${target%% *}
    rest=${target#* }
    flags=${rest% *}
    base=${rest##* }
    [[ $(curl -sS $flags "$base/events" | tr '\n' '|') == 'data: event 0||data: event 1||data: event 2||data: event 3||data: event 4||' ]] || { echo "http2 stream server ($label): the events are wrong" >&2; exit 1; }
    [[ $(curl -sS $flags "$base/") == 'hello h2' ]] || { echo "http2 stream server ($label): the buffered route changed" >&2; exit 1; }
    curl -sS $flags --data-binary "@$out/body.bin" -o "$out/echo.out" "$base/echo"
    cmp -s "$out/body.bin" "$out/echo.out" || { echo "http2 stream server ($label): the echo of 1.5 MB differs" >&2; exit 1; }
    [[ $(curl -sS $flags --data-binary "@$out/body.bin" "$base/sink") == 'received 1500000' ]] || { echo "http2 stream server ($label): the sink miscounted" >&2; exit 1; }
    [[ $(curl -sS $flags "$base/big?n=3000000" | wc -c) == 3000000 ]] || { echo "http2 stream server ($label): the 3 MB download is not 3000000 bytes" >&2; exit 1; }
    [[ $(curl -sS $flags -o /dev/null -w '%{http_code}' --data-binary "@$out/body.bin" "$base/limited") == 413 ]] || { echo "http2 stream server ($label): a body over the route's limit was not refused with 413" >&2; exit 1; }
    head -c 50000 "$out/body.bin" > "$out/small.bin"
    [[ $(curl -sS $flags --data-binary "@$out/small.bin" "$base/limited") == 'received 50000' ]] || { echo "http2 stream server ($label): a body within the limit was refused" >&2; exit 1; }
    echo "http2 stream server ($label): curl ok (events, echo, sink, download, body limit)"
done

run() {   # run LABEL PORT CA MODE BYTES PATH
    local label=$1 result peak
    result=$("$root/tools/run-limited.sh" "$out/streamnet" "$2" "$3" "$4" "$5" "$6") || { echo "http2 stream server ($label): $result" >&2; tail -5 "$out"/*.log >&2; exit 1; }
    [[ $result == "http2 streamnet $4 ok"* ]] || { echo "http2 stream server ($label): $result" >&2; exit 1; }
    peak=${result##*peak resident }
    peak=${peak%% KiB*}
    (( peak < client_limit )) || { echo "http2 stream server ($label): the client's peak resident memory was $peak KiB, over $client_limit KiB" >&2; exit 1; }
    echo "http2 stream server ($label): $result"
}
run "download over h2c" "$plain_port" - down "$bytes" "/big?n=$bytes"
run "upload over h2c" "$plain_port" - up "$bytes" /sink
run "echo over h2c" "$plain_port" - echo $((bytes / 4)) /echo
run "download over TLS" "$tls_port" "$out/p256.pem" down "$tls_bytes" "/big?n=$tls_bytes"
run "upload over TLS" "$tls_port" "$out/p256.pem" up "$tls_bytes" /sink
run "echo over TLS" "$tls_port" "$out/p256.pem" echo "$tls_bytes" /echo
run "a consumer that stops reading" "$plain_port" - slow 33554432 /big?n=33554432
run "a request body nobody takes" "$plain_port" - upstall 33554432 /stall
grep -q '^abort /stall' "$out/plain.log" || { echo "http2 stream server: the server never heard of the stalled exchange ending" >&2; cat "$out/plain.log" >&2; exit 1; }

# The servers' own memory: what they peaked at over everything above.
for name in plain tls; do
    pid_var=${name}_pid
    pid=${!pid_var}
    peak_kib=$(sed -n 's/^VmHWM:[[:space:]]*\([0-9]*\) kB.*/\1/p' "/proc/$pid/status")
    [[ -n $peak_kib ]] || { echo "http2 stream server: no VmHWM for the $name server" >&2; exit 1; }
    (( peak_kib < limit )) || { echo "http2 stream server: the $name server peaked at $peak_kib KiB of resident memory, over $limit KiB" >&2; exit 1; }
    echo "http2 stream server: the $name server's peak resident memory: $peak_kib KiB (limit $limit KiB)"
done
echo "http2 stream server ok"
