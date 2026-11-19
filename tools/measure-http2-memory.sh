#!/usr/bin/env bash
# The HTTP/2 server's memory per idle connection and per open stream (tests/cases/http2/hold.ab, tools/h2spec/server.ab), read from the server's own VmRSS and VmHWM:
#   baseline    the server just started
#   idle TLS    h2load -c N connections held open over TLS with ALPN h2 (one request per second each), RSS minus baseline over N
#   idle h2c    N plain connections after the HTTP/2 preface, no stream
#   streams     N h2c connections with S unfinished streams each (a request that has its HEADERS and no END_STREAM), RSS minus the idle h2c RSS over N*S
# Usage: tools/measure-http2-memory.sh [compiler] (MEASURE_CONNECTIONS=500, MEASURE_STREAMS=50). Prints the figures; they are in docs/networking.md.
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/http2-memory
rm -rf "$out"
mkdir -p "$out"
n=${MEASURE_CONNECTIONS:-500}
s=${MEASURE_STREAMS:-50}
for tool in openssl h2load; do command -v "$tool" > /dev/null || { echo "measure-http2-memory: $tool is needed" >&2; exit 1; }; done
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/p256.key" 2> /dev/null
openssl req -x509 -new -key "$out/p256.key" -out "$out/p256.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost' -days 2 2> /dev/null
for program in server:tools/h2spec/server.ab hold:tests/cases/http2/hold.ab; do
    "$compiler" build "${program#*:}" -o "$out/${program%%:*}" --no-cache > "$out/${program%%:*}.build.log" 2>&1 || { cat "$out/${program%%:*}.build.log" >&2; exit 1; }
done
pid=
trap '[[ -z $pid ]] || kill "$pid" 2> /dev/null || true' EXIT
start() {   # start ARGS...: the server, $port and $pid set
    [[ -z $pid ]] || { kill "$pid" 2> /dev/null || true; wait "$pid" 2> /dev/null || true; }
    ABLA_MAX_MEMORY_MB=0 "$out/server" 0 "$@" > "$out/server.log" 2>&1 &
    pid=$!
    for _ in $(seq 600); do
        port=$(sed -n 's/^listening //p' "$out/server.log" | head -1)
        [[ -n $port ]] && return 0
        sleep 0.1
    done
    echo "measure-http2-memory: the server did not start" >&2
    exit 1
}
rss() { awk '/^VmRSS:/ {print $2}' "/proc/$pid/status"; }
hwm() { awk '/^VmHWM:/ {print $2}' "/proc/$pid/status"; }
fds() { ls "/proc/$pid/fd" | wc -l; }

start "$root/$out/p256.pem" "$root/$out/p256.key"
base=$(rss)
echo "baseline (TLS server, no connection): $base KiB"
h2load -D 12 -c "$n" -m 1 -t 2 --rps 1 "https://localhost:$port/x" > "$out/h2load.log" 2>&1 &
load=$!
sleep 8
tls=$(rss)
open=$(( $(fds) ))
wait "$load" || true
echo "idle TLS: $tls KiB with ~$((open - 8)) descriptors open: $(( (tls - base) * 1024 / n )) bytes per connection (h2load -c $n)"
echo "peak after the TLS run: $(hwm) KiB; after the connections closed: $(rss) KiB"
h2load -D 6 -c "$n" -m 1 -t 2 --rps 1 "https://localhost:$port/x" > "$out/h2load2.log" 2>&1 &
load=$!
sleep 4
echo "a second wave of $n connections (the first one closed): $(rss) KiB (growth over the first: $(( $(rss) - tls )) KiB)"
wait "$load" || true

start h2only
base=$(rss)
echo "baseline (h2c server, no connection): $base KiB"
"$out/hold" "$port" "$n" 0 10 > "$out/hold0.log" 2>&1 &
holder=$!
sleep 6
idle=$(rss)
wait "$holder" || true
echo "idle h2c: $idle KiB: $(( (idle - base) * 1024 / n )) bytes per connection ($n connections, no stream)"
"$out/hold" "$port" "$n" "$s" 10 > "$out/hold1.log" 2>&1 &
holder=$!
sleep 6
busy=$(rss)
wait "$holder" || true
echo "streams: $busy KiB with $s open streams on each of $n connections: $(( (busy - idle) * 1024 / (n * s) )) bytes per open stream"
echo "peak after the stream run: $(hwm) KiB; $(cat "$out/hold1.log" | tail -1)"
