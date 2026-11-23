#!/usr/bin/env bash
# The TLS handshake differential (#1139 area 3, TLS round 2): hostile hellos sent to, and from, abla/tls/pure, OpenSSL and Go's crypto/tls, and what each one does
# compared. Needs openssl and go on the PATH. Two halves:
#
#   clienthello  a valid ClientHello changed structurally (diff.ab) goes to three servers at once: ours (server.ab), `openssl s_server` and a Go crypto/tls server
#                (peer.go); each answers with a ServerHello (accept), an alert, a close or nothing. Output per mutation family: how often each ours/openssl/go
#                combination came out, and an `ODD` line for every input where ours was alone against both others.
#   serverhello  our hostile server (hello-server.ab) changes a ServerHello built from the client's own ClientHello (hello-server.ab lists the changes) and each client
#                (ours: client.ab; `openssl s_client`; Go: client.go) connects to it in turn; what it does next is read off the wire (an alert or close: refused;
#                a ChangeCipherSpec, a second ClientHello or silence: not refused). The same case index is the same change on every port; the cases are joined.
#
#   tools/tls-diff/run.sh COMPILER clienthello INSTANCES FIRST_SEED SEEDS_PER_INSTANCE INPUTS_PER_SEED
#   tools/tls-diff/run.sh COMPILER serverhello INSTANCES FIRST_SEED CASES_PER_INSTANCE
#
# The output goes to build/tls-diff/: clienthello.out (the COUNT and ODD lines), serverhello.txt (one joined line per case: instance:index tags ours openssl go) and
# a summary on standard output. "Ours is lenient" (we accept what both others refuse) is the line to read first; "ours is stricter" is an interoperability risk
# only when it is not about something we do not offer (a HelloRetryRequest for a group we never sent, an extension we did not ask for). Each instance runs its servers
# on ports 24000+10*k (clienthello) and 26000+10*k (serverhello).
set -euo pipefail
compiler=${1:?usage: run.sh COMPILER clienthello|serverhello INSTANCES FIRST_SEED N [INPUTS]}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
mode=$2 instances=$3 first=$4 count=$5 inputs=${6:-40}
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$root"
for tool in openssl go; do command -v $tool > /dev/null || { echo "tls-diff: needs $tool; skipped" >&2; exit 0; }; done
out=build/tls-diff
mkdir -p "$out"
if [[ ! -f $out/c.pem ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$out/k.pem" -out "$out/c.pem" -subj /CN=localhost \
        -addext subjectAltName=DNS:localhost -days 2 2> /dev/null
fi
build() { "$compiler" build "tools/tls-diff/$1.ab" -o "$out/$1" --fast --no-cache > "$out/$1.build.log" 2>&1 || { cat "$out/$1.build.log" >&2; exit 2; }; }
(cd tools/tls-diff && go build -o "../../$out/peer" peer.go client.go)
pids=()
cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2> /dev/null || true; done; pkill -f "s_server -accept 127.0.0.1:2[46]" 2> /dev/null || true; }
trap cleanup EXIT
if [[ $mode == clienthello ]]; then
    build server
    build diff
    for k in $(seq 0 $((instances - 1))); do
        port=$((24000 + k * 10))
        "$out/server" "$out/c.pem" "$out/k.pem" $port > "$out/server$k.log" 2>&1 & pids+=($!)
        (sleep 3000 | openssl s_server -accept 127.0.0.1:$((port + 1)) -cert "$out/c.pem" -key "$out/k.pem" -quiet -www) > "$out/openssl$k.log" 2>&1 & pids+=($!)
        "$out/peer" server $((port + 2)) "$out/c.pem" "$out/k.pem" > "$out/go$k.log" 2>&1 & pids+=($!)
    done
    sleep 2
    runs=()
    for k in $(seq 0 $((instances - 1))); do
        port=$((24000 + k * 10))
        timeout 3000 "$out/diff" $port $((port + 1)) $((port + 2)) $((first + k * count)) "$count" "$inputs" > "$out/diff$k.out" 2>&1 & runs+=($!)
    done
    for pid in "${runs[@]}"; do wait "$pid" || true; done
    cat "$out"/diff[0-9]*.out > "$out/clienthello.out"
    grep -h '^tls-diff\|^FINDING' "$out"/diff[0-9]*.out
    echo "ours is lenient (accepts what OpenSSL and Go both refuse), one change at a time:"
    { grep '^ODD acc/rej/rej' "$out/clienthello.out" || true; } | sed 's/ODD acc\/rej\/rej seed [0-9]* n [0-9]* //' | { grep -v '+' || true; } | sort | uniq -c | sort -rn
    echo "ours is stricter (refuses what both accept), one change at a time:"
    { grep '^ODD rej/acc/acc' "$out/clienthello.out" || true; } | sed 's/ODD rej\/acc\/acc seed [0-9]* n [0-9]* //' | { grep -v '+' || true; } | sort | uniq -c | sort -rn
else
    build hello-server
    build client
    n=$count
    rm -f "$out"/hs-*.out
    for k in $(seq 0 $((instances - 1))); do
        port=$((26000 + k * 10)); seed=$((first + k))
        for who in ours openssl go; do
            case $who in ours) p=$port ;; openssl) p=$((port + 1)) ;; go) p=$((port + 2)) ;; esac
            "$out/hello-server" $p $seed $n > "$out/hs-$k-$who.out" 2>&1 & pids+=($!)
        done
    done
    sleep 2
    runs=()
    for k in $(seq 0 $((instances - 1))); do
        port=$((26000 + k * 10))
        ("$out/client" $port $n; "$out/peer" client $((port + 2)) $n) > /dev/null 2>&1 & runs+=($!)
        (for i in $(seq 1 $n); do timeout 1 openssl s_client -connect 127.0.0.1:$((port + 1)) -tls1_3 < /dev/null > /dev/null 2>&1 || true; done) > /dev/null 2>&1 & runs+=($!)
    done
    for pid in "${runs[@]}"; do wait "$pid" || true; done
    : > "$out/serverhello.txt"
    for k in $(seq 0 $((instances - 1))); do
        paste -d' ' <(grep '^CASE' "$out/hs-$k-ours.out" | sort -k2,2n) <(grep '^CASE' "$out/hs-$k-openssl.out" | sort -k2,2n | awk '{print $NF}') \
            <(grep '^CASE' "$out/hs-$k-go.out" | sort -k2,2n | awk '{print $NF}') | awk -v k=$k '{print k ":" $2, $3, $4, $5, $6}' >> "$out/serverhello.txt"
    done
    awk '
    function cls(x) { if (x ~ /^A/ || x == "C") return "rej"; return "ok" }
    { o=cls($3); s=cls($4); g=cls($5); t=o "/" s "/" g; n[t]++; fam=$2; sub(/[+].*/, "", fam)
      if (s==g && o!=s && $2 !~ /[+]/) c[t " " fam]++ }
    END { print "serverhello: " NR " cases"; for (k in n) print "  ours/openssl/go " k ": " n[k]
          print "ours alone against both others, one change at a time (rej/ok/ok: stricter, ok/rej/rej: lenient):"; for (k in c) print "  " c[k] " " k }' "$out/serverhello.txt" | sort
fi
