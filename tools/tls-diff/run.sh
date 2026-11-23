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
#   tools/tls-diff/run.sh COMPILER flight|flight12|cflight|cflightauth|cflight12|cresume INSTANCES FIRST_SEED CASES_PER_INSTANCE   (round 3: see below)
#
# Round 3 (the encrypted part of the handshake, with a real handshake behind each case; flight.sh and cflight.sh print the combinations and the LENIENT and STRICT lines):
#   flight      our client against a hostile TLS 1.3 server (flight-server.ab) that changes its encrypted flight and the post-handshake messages, against openssl s_client and Go
#   flight12    the same for TLS 1.2 (flight12-server.ab)
#   cflight     our server against a hostile TLS 1.3 client (cflight.ab) that changes its Finished flight and the post-handshake messages, against openssl s_server and Go
#   cflightauth the same with client certificates required: the Certificate and CertificateVerify are changed too
#   cflight12   the same for TLS 1.2 (cflight12.ab)
#   cresume     round 4: a full handshake that leaves a ticket, then a resumption whose ClientHello is changed (the ticket, the binder, the age, several identities,
#               psk_key_exchange_modes, early_data and early data records, the server name, the suite); ours (server-resume.ab, with ticket keys) against s_server and Go.
#               R = the ServerHello selected the PSK. LENIENT = ours resumed what both others did not: a forged or damaged resumption accepted.
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
cleanup() { for pid in "${pids[@]}"; do kill "$pid" 2> /dev/null || true; done; pkill -f "s_server -accept 127.0.0.1:(2[46]|3[01])" 2> /dev/null || true; }
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
elif [[ $mode == flight || $mode == flight12 || $mode == cflight || $mode == cflightauth || $mode == cflight12 || $mode == cresume ]]; then
    # Round 3 (tools/tls-diff/flight.sh, cflight.sh): the encrypted flights. INSTANCES run at once, seeds FIRST_SEED+k, COUNT connections each, on ports 31000+100*k.
    case $mode in
        flight) programs=(flight-server flight-client) ;;
        flight12) programs=(flight12-server flight-client) ;;
        cflight | cflightauth) programs=(cflight server) ;;
        cflight12) programs=(cflight12 server) ;;
        cresume) programs=(cresume server-resume) ;;
    esac
    for program in "${programs[@]}"; do build "$program"; done
    runs=()
    for k in $(seq 0 $((instances - 1))); do
        case $mode in
            flight) FLIGHT_PORT=$((31000 + 100 * k)) tools/tls-diff/flight.sh "$out/$mode-$k" "$out" $((first + k)) "$count" "$PWD/$out/c.pem" "$PWD/$out/k.pem" > "$out/$mode-$k.sum" 2>&1 & runs+=($!) ;;
            flight12) FLIGHT_TLS12=1 FLIGHT_PORT=$((31000 + 100 * k)) tools/tls-diff/flight.sh "$out/$mode-$k" "$out" $((first + k)) "$count" "$PWD/$out/c.pem" "$PWD/$out/k.pem" > "$out/$mode-$k.sum" 2>&1 & runs+=($!) ;;
            cflight) CFLIGHT_PORT=$((31000 + 100 * k)) tools/tls-diff/cflight.sh "$out/$mode-$k" "$out" $((first + k)) "$count" "$PWD/$out/c.pem" "$PWD/$out/k.pem" > "$out/$mode-$k.sum" 2>&1 & runs+=($!) ;;
            cflightauth) CFLIGHT_AUTH=1 CFLIGHT_PORT=$((31000 + 100 * k)) tools/tls-diff/cflight.sh "$out/$mode-$k" "$out" $((first + k)) "$count" "$PWD/$out/c.pem" "$PWD/$out/k.pem" > "$out/$mode-$k.sum" 2>&1 & runs+=($!) ;;
            cresume) CFLIGHT_RESUME=1 CFLIGHT_PORT=$((31000 + 100 * k)) tools/tls-diff/cflight.sh "$out/$mode-$k" "$out" $((first + k)) "$count" "$PWD/$out/c.pem" "$PWD/$out/k.pem" > "$out/$mode-$k.sum" 2>&1 & runs+=($!) ;;
            cflight12) CFLIGHT_TLS12=1 CFLIGHT_PORT=$((31000 + 100 * k)) tools/tls-diff/cflight.sh "$out/$mode-$k" "$out" $((first + k)) "$count" "$PWD/$out/c.pem" "$PWD/$out/k.pem" > "$out/$mode-$k.sum" 2>&1 & runs+=($!) ;;
        esac
    done
    for pid in "${runs[@]}"; do wait "$pid" || true; done
    echo "$mode: ours alone against both others, one change at a time (LENIENT: ours takes what both refuse; STRICT: ours refuses what both take):"
    { cat "$out"/$mode-*.sum | grep -E '^(LENIENT|STRICT)' || true; } | awk '{ tags = $3; n[$1 " " tags " " $4 " " $5 " " $6]++ } END { for (k in n) print "  " n[k] " " k }' | sort -rn
    echo "$mode: $(cat "$out"/$mode-*/*.txt | wc -l) cases joined (the lines are in $out/$mode-K/*.txt)"
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
