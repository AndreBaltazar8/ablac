#!/usr/bin/env bash
# The TLS handshake differential (tools/tls-diff, #1139 area 3) as a bounded check of the suite, so a difference from OpenSSL and Go cannot come back unseen:
#   1. the directed cases of the first campaign's findings (diff.ab regress): a valid hello every server takes, and four malformed ClientHello extension bodies
#      (an empty supported_versions list, an empty ALPN list, early_data with a body, a truncated status_request) that OpenSSL and Go both refuse: our server must not take
#      them;
#   2. 1,000 mutated ClientHellos to our server, `openssl s_server` and a Go crypto/tls server: no single change that ours takes and both others refuse;
#   3. 300 changed ServerHellos from our hostile server to our client, `openssl s_client` and Go: no single change (flipped bytes excepted: a flip can leave one client's own
#      bytes as they were) that our client takes and both others refuse.
# A server that is gone is reported as that ("DEAD", the process died or never started), not as a difference. Skipped, with a message, without openssl or go.
# Every server listens on a port the kernel picks (port 0), read back from its "listening" (ACCEPT for OpenSSL) line, and each run has its
# own output directory: two runs at once (merge gates side by side) cannot take each other's ports or kill each other's servers.
# Takes under a minute besides the four release-less (--fast) builds. Usage: tools/test-tls-diff.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
. "$root/tools/lib/openssl-server.sh"
for tool in openssl go; do
    command -v $tool > /dev/null || { echo "tls-diff: no $tool; skipped"; exit 0; }
done
mkdir -p build
out=$(mktemp -d "$root/build/tls-diff-test.XXXXXXXX")
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$out/k.pem" -out "$out/c.pem" -subj /CN=localhost \
    -addext subjectAltName=DNS:localhost -days 2 2> /dev/null
pids=()
for program in server diff hello-server client; do
    "$compiler" build "tools/tls-diff/$program.ab" -o "$out/$program" --fast --no-cache > "$out/$program.build.log" 2>&1 &
    pids+=("$!")
done
(cd tools/tls-diff && go build -o "$out/peer" peer.go client.go) &
pids+=("$!")
for pid in "${pids[@]}"; do wait "$pid" || { cat "$out"/*.build.log >&2; echo "tls-diff: a program did not build" >&2; exit 1; }; done
pids=()
servers=()
cleanup() {
    local status=$?
    for pid in "${servers[@]}"; do kill "$pid" 2> /dev/null || true; done
    if ((status == 0)); then rm -rf "$out"; else echo "tls-diff: logs in $out" >&2; fi
}
trap cleanup EXIT
dead() { echo "tls-diff: DEAD: $1 (the server process died or never started; this is not a difference from OpenSSL or Go)" >&2; tail -n 3 "$out/$2.log" >&2 || true; exit 1; }
# listening FILE PATTERN: the port in FILE's first line matching PATTERN (its last number), once it is there; empty after 10 s.
listening() {
    local wait_for line
    for ((wait_for = 0; wait_for < 100; wait_for++)); do
        line=$(grep -m 1 -E "$2" "$1" 2> /dev/null || true)
        [[ -n $line ]] && { grep -oE "[0-9]+\$" <<< "$line"; return; }
        sleep 0.1
    done
}
"$out/server" "$out/c.pem" "$out/k.pem" 0 > "$out/server.log" 2>&1 &
ours=$!
servers+=("$ours")
# OpenSSL on a port the kernel picks (tools/lib/openssl-server.sh), its stdin kept open: it would stop at its end.
OPENSSL_SERVER_INHERIT_STDIN=1 openssl_server_start "$out/openssl.log" 127.0.0.1:0 -cert "$out/c.pem" -key "$out/k.pem" -www < <(sleep 900) ||
    dead "openssl s_server did not start" openssl
servers+=("$openssl_server_pid")
openssl_port=$openssl_server_port
"$out/peer" server 0 "$out/c.pem" "$out/k.pem" > "$out/go.log" 2>&1 &
go_server=$!
servers+=("$go_server")
our_port=$(listening "$out/server.log" "^listening [0-9]+\$")
go_port=$(listening "$out/go.log" "^listening [0-9]+\$")
sleep 1
kill -0 "$ours" 2> /dev/null || dead "our server" server
kill -0 "$go_server" 2> /dev/null || dead "the Go server" go
[[ -n $our_port ]] || dead "our server printed no port" server
[[ -n $go_port ]] || dead "the Go server printed no port" go
status=0
timeout 120 "$out/diff" "$our_port" "$openssl_port" "$go_port" 1 1 regress > "$out/regress.out" 2>&1 || status=$?
cat "$out/regress.out"
[[ $status -ne 3 ]] || dead "our server went away during the directed cases" server
[[ $status -eq 0 ]] || { echo "tls-diff: the directed cases failed (status $status)" >&2; exit 1; }
timeout 120 "$out/diff" "$our_port" "$openssl_port" "$go_port" 1 25 40 > "$out/clienthello.out" 2>&1 || { tail -n 5 "$out/clienthello.out" >&2; kill -0 "$ours" 2> /dev/null || dead "our server went away during the campaign" server; echo "tls-diff: the ClientHello campaign failed" >&2; exit 1; }
kill -0 "$ours" 2> /dev/null || dead "our server went away during the campaign" server
if grep -q '^FINDING' "$out/clienthello.out"; then grep '^FINDING' "$out/clienthello.out" >&2; exit 1; fi
lenient=$(grep '^ODD acc/rej/rej' "$out/clienthello.out" | grep -v '+' || true)
if [[ -n $lenient ]]; then
    echo "tls-diff: our server takes a ClientHello change that OpenSSL and Go both refuse:" >&2
    echo "$lenient" | head -n 5 >&2
    exit 1
fi
echo "tls-diff clienthello: $(grep -c . "$out/clienthello.out") lines, $(grep '^tls-diff clienthello' "$out/clienthello.out" | head -n 1)"
# The ServerHello half.
n=300
# One hostile server per client (ours, OpenSSL's, Go's), each on a port the kernel picks.
hello_ports=()
for index in 0 1 2; do
    "$out/hello-server" 0 1 $n > "$out/hs-$index.out" 2>&1 &
    servers+=("$!")
done
for index in 0 1 2; do
    hello_ports+=("$(listening "$out/hs-$index.out" "^listening [0-9]+\$")")
    [[ -n ${hello_ports[$index]} ]] || dead "hostile server $index printed no port" "hs-$index"
done
"$out/client" "${hello_ports[0]}" $n > /dev/null 2>&1 &
client_pid=$!
"$out/peer" client "${hello_ports[2]}" $n > /dev/null 2>&1 &
go_client=$!
(for ((i = 0; i < n; i++)); do timeout 1 openssl s_client -connect "127.0.0.1:${hello_ports[1]}" -tls1_3 < /dev/null > /dev/null 2>&1 || true; done) > /dev/null 2>&1 &
openssl_clients=$!
wait "$client_pid" "$go_client" "$openssl_clients" || true
sleep 1
for index in 0 1 2; do
    [[ $(grep -c '^CASE' "$out/hs-$index.out") -eq $n ]] || { echo "tls-diff: the hostile server on port ${hello_ports[$index]} served $(grep -c '^CASE' "$out/hs-$index.out") of $n cases" >&2; exit 1; }
done
paste -d' ' <(grep '^CASE' "$out/hs-0.out" | sort -k2,2n) <(grep '^CASE' "$out/hs-1.out" | sort -k2,2n | awk '{print $NF}') \
    <(grep '^CASE' "$out/hs-2.out" | sort -k2,2n | awk '{print $NF}') | awk '{print $2, $3, $4, $5, $6}' > "$out/serverhello.txt"
lenient=$(awk 'function cls(x) { if (x ~ /^A/ || x == "C") return "rej"; return "ok" }
    { if (cls($3) == "ok" && cls($4) == "rej" && cls($5) == "rej" && $2 !~ /[+]/ && $2 !~ /^flip/) print }' "$out/serverhello.txt")
if [[ -n $lenient ]]; then
    echo "tls-diff: our client takes a ServerHello change that OpenSSL and Go both refuse:" >&2
    echo "$lenient" | head -n 5 >&2
    exit 1
fi
echo "tls-diff: the directed cases, 1,000 ClientHellos and $n ServerHellos agree with OpenSSL and Go where it matters (ours is never alone in taking what both refuse)"
