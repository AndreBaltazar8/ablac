#!/usr/bin/env bash
# HTTP/2 against HTTP/1.1 for abla/http/async: latency (p50, p99) and total time for N parallel requests to one origin, against h2o (both protocols on one
# port: the same server, only the client's `http2` option differs), our own HttpsEventServer (tests/cases/http2/streamserver.ab, both protocols too) and nghttpd
# (HTTP/2 only), for small and 64 KiB bodies, cold (a fresh client: the handshakes are in the time) and warm (connections exist). Each cell is the median by
# throughput of REPEATS runs. Server and client run on separate CPUs (SERVER_CPUS, CLIENT_CPUS). Needs openssl, nghttpd and h2o (nix-shell -p h2o nghttp2).
#   tools/bench-http2-client.sh [compiler]       env: TOTAL=2000 REPEATS=3 PARALLEL="1 8 32 128" SIZES="1024 65536" SERVERS="h2o ours nghttpd" SERVER_CPUS=0-1 CLIENT_CPUS=2-3
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
total=${TOTAL:-2000}; repeats=${REPEATS:-3}; parallel=${PARALLEL:-"1 8 32 128"}; sizes=${SIZES:-"1024 65536"}
server_cpus=${SERVER_CPUS:-0-1}; client_cpus=${CLIENT_CPUS:-2-3}
out=build/bench-http2
rm -rf "$out"; mkdir -p "$out/docroot"
for tool in openssl nghttpd h2o; do command -v "$tool" > /dev/null || { echo "bench-http2: $tool is needed (nix-shell -p h2o nghttp2)" >&2; exit 1; }; done
openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$out/key.pem" 2> /dev/null
openssl req -x509 -new -key "$out/key.pem" -out "$out/cert.pem" -subj /CN=localhost -addext 'subjectAltName=DNS:localhost' -days 2 2> /dev/null
for size in $sizes; do head -c "$size" /dev/urandom > "$out/docroot/$size.bin"; done
"$compiler" build tests/cases/http2/bench.ab -o "$out/bench" --no-cache
"$compiler" build tests/cases/http2/streamserver.ab -o "$out/streamserver" --no-cache
pids=()
trap 'for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done' EXIT
free_port() { while :; do c=$((20000 + RANDOM % 20000)); ss -ltn "sport = :$c" 2> /dev/null | grep LISTEN > /dev/null || { echo "$c"; return; }; done; }
wait_port() { for _ in $(seq 100); do ss -ltn "sport = :$1" 2> /dev/null | grep LISTEN > /dev/null && return 0; sleep 0.1; done; echo "bench-http2: nothing listens on $1" >&2; exit 1; }

h2o_port=$(free_port)
cat > "$out/h2o.conf" <<CONF
listen:
  port: $h2o_port
  ssl:
    certificate-file: $root/$out/cert.pem
    key-file: $root/$out/key.pem
hosts:
  default:
    paths:
      /:
        file.dir: $root/$out/docroot
access-log: /dev/null
error-log: $root/$out/h2o.err
CONF
taskset -c "$server_cpus" h2o -c "$out/h2o.conf" > "$out/h2o.log" 2>&1 & pids+=($!)
nghttpd_port=$(free_port)
taskset -c "$server_cpus" nghttpd -d "$out/docroot" "$nghttpd_port" "$out/key.pem" "$out/cert.pem" > "$out/nghttpd.log" 2>&1 & pids+=($!)
ours_port=$(free_port)
taskset -c "$server_cpus" "$out/streamserver" "$ours_port" "$out/cert.pem" "$out/key.pem" > "$out/ours.log" 2>&1 & pids+=($!)
wait_port "$h2o_port"; wait_port "$nghttpd_port"; wait_port "$ours_port"

# url SERVER SIZE
url() {
    case $1 in
        h2o) echo "https://localhost:$h2o_port/$2.bin" ;;
        nghttpd) echo "https://localhost:$nghttpd_port/$2.bin" ;;
        ours) echo "https://localhost:$ours_port/big?n=$2" ;;
    esac
}
results="$out/results.txt"
: > "$results"
for server in ${SERVERS:-h2o ours nghttpd}; do
    for size in $sizes; do
        for mode in cold warm; do
            for n in $parallel; do
                for h2 in 0 1; do
                    [[ $server == nghttpd && $h2 == 0 ]] && continue
                    for run in $(seq "$repeats"); do
                        line=$(taskset -c "$client_cpus" "$out/bench" "$(url "$server" "$size")" "$n" "$total" "$h2" "$root/$out/cert.pem" "$mode" 2>&1 || true)
                        echo "$server $size $mode $line" >> "$results"
                    done
                done
            done
        done
    done
done
# The table: per cell the run with the median rps.
awk '
{ key = $1 " " $2 " " $3 " " $4 " " $5; rps = $8; sub("rps=", "", rps); line[key, ++count[key]] = $0; value[key, count[key]] = rps + 0; keys[key] = 1 }
END {
    for (key in keys) {
        n = count[key]
        for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (value[key, j] < value[key, i]) { t = value[key, i]; value[key, i] = value[key, j]; value[key, j] = t; t = line[key, i]; line[key, i] = line[key, j]; line[key, j] = t }
        print line[key, int((n + 1) / 2)]
    }
}' "$results" | sort -V > "$out/median.txt"
echo "server size mode proto parallel total time_ms rps p50_us p90_us p99_us max_us errors protocol"
cat "$out/median.txt"
