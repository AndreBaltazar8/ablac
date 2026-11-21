#!/usr/bin/env bash
# One sample. The slot is held by the parent; one server worker, one client.
set -euo pipefail
binary=$1 stem=$2 payload=$3 requests=$4 cpu=$5
export no_proxy=127.0.0.1 NO_PROXY=127.0.0.1
server_pid=
cleanup(){ [[ -n $server_pid ]] && kill "$server_pid" 2>/dev/null || true; [[ -n $server_pid ]] && wait "$server_pid" 2>/dev/null || true; }
trap cleanup EXIT
# Select an unused ephemeral loopback port through the server's bind retry. No
# persistent service is contacted: readiness is accepted only while our pid lives.
for ((attempt=0;attempt<20;attempt++)); do
    port=$((20000 + RANDOM))
    taskset -c "$cpu" "$binary" "$port" > "$stem.server.stdout" 2> "$stem.server.stderr" &
    server_pid=$!
    ready=0
    for ((poll=0;poll<40;poll++)); do
        kill -0 "$server_pid" 2>/dev/null || break
        if curl --silent --fail --max-time 1 -H 'Expect:' --data-binary "@$payload" "http://127.0.0.1:$port/" > "$stem.echo"; then
            kill -0 "$server_pid" 2>/dev/null || break
            cmp "$stem.echo" "$payload"
            ready=1; break
        fi
        sleep 0.025
    done
    ((ready)) && break
    cleanup; server_pid=
done
((ready)) || { echo 'server failed to bind/become ready' >&2; exit 1; }
# Warm HTTP path before sampling. stdout JSON preserves status and error counts.
oha --no-tui --worker-threads 1 --disable-keepalive -c 1 -n 100 -m POST -D "$payload" -H 'Content-Type: application/octet-stream' "http://127.0.0.1:$port/" > "$stem.warmup.log"
oha --no-tui --output-format json --worker-threads 1 --disable-keepalive -c 1 -n "$requests" -m POST -D "$payload" -H 'Content-Type: application/octet-stream' "http://127.0.0.1:$port/" > "$stem.oha.json"
# Exact response size/count, status and no transport errors; curl also compares
# body bytes before and after load. The timed client does not hash each body.
jq -e --argjson n "$requests" '(.summary.successRate==1) and (.statusCodeDistribution["200"]==$n) and ((.errorDistribution|length)==0) and (.summary.totalData==$n*256)' "$stem.oha.json" > /dev/null
curl --silent --fail --max-time 2 -H 'Expect:' --data-binary "@$payload" "http://127.0.0.1:$port/" > "$stem.echo-after"
cmp "$stem.echo-after" "$payload"
rss=$(awk '/^VmHWM:/{print $2*1024}' "/proc/$server_pid/status")
[[ $rss =~ ^[0-9]+$ ]] || exit 1
jq --argjson rss "$rss" '{wallSeconds:.summary.total,requestsPerSecond:.summary.requestsPerSec,rssBytes:$rss}' "$stem.oha.json" > "$stem.metrics.json"
