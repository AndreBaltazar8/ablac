#!/usr/bin/env bash
# The encrypted-flight differential (#1139 area 3, TLS round 3): tools/tls-diff/flight-server.ab serves COUNT mutated server flights to each of three clients (ours,
# `openssl s_client`, Go crypto/tls) and prints, per connection, what each did. Usage: tools/tls-diff/flight.sh OUTDIR PROGRAMS_DIR SEED COUNT [CERT KEY]
# PROGRAMS_DIR holds flight-server, flight-client and peer (built as in tools/test-tls-diff.sh). Lines: "CASE i tags ours openssl go", then the summary of
# disagreements: LENIENT (ours takes what both others refuse), STRICT (ours refuses what both others take), and the rest.
set -euo pipefail
out=$1 programs=$2 seed=$3 count=$4
mkdir -p "$out"
cert=${5:-$out/c.pem}
key=${6:-$out/k.pem}
# Round 5: FLIGHT_SUITE (4865 AES-128-GCM, 4866 AES-256-GCM, 4867 ChaCha20-Poly1305), FLIGHT_KIND (p256, p384, ed25519, rsa: the server's key, in OUTDIR when it is not p256) and
# FLIGHT_HRR=1 (a HelloRetryRequest for P-256 first) change what the TLS 1.3 server does; the TLS 1.2 server ignores them.
suite=${FLIGHT_SUITE:-4865}
kind=${FLIGHT_KIND:-p256}
hrr_argument=()
[[ -n ${FLIGHT_HRR:-} ]] && hrr_argument=(hrr)
if [[ $kind != p256 ]]; then
    cert=$out/c-$kind.pem
    key=$out/k-$kind.pem
fi
if [[ ! -f $cert ]]; then
    case $kind in
        p256) algorithm=(-newkey ec -pkeyopt ec_paramgen_curve:prime256v1) ;;
        p384) algorithm=(-newkey ec -pkeyopt ec_paramgen_curve:secp384r1) ;;
        ed25519) algorithm=(-newkey ed25519) ;;
        rsa) algorithm=(-newkey rsa:2048) ;;
        *) echo "flight: unknown FLIGHT_KIND $kind" >&2; exit 2 ;;
    esac
    openssl req -x509 "${algorithm[@]}" -nodes -keyout "$key" -out "$cert" -subj /CN=localhost -addext subjectAltName=DNS:localhost -days 2 2> /dev/null
fi
base=${FLIGHT_PORT:-29000}
server_program=flight-server
client_mode=flight
openssl_version=-tls1_3
if [[ -n ${FLIGHT_TLS12:-} ]]; then
    server_program=flight12-server
    client_mode=flight12
    openssl_version=-tls1_2
fi
pids=()
trap 'for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done' EXIT
for index in 0 1 2; do
    "$programs/$server_program" $((base + index)) "$seed" "$count" "$cert" "$key" -1 "$suite" "$kind" "${hrr_argument[@]}" > "$out/fs-$index.out" 2>&1 &
    pids+=("$!")
done
for ((w = 0; w < 100; w++)); do
    [[ $(grep -l listening "$out"/fs-[012].out 2> /dev/null | wc -l) -eq 3 ]] && break
    sleep 0.1
done
"$programs/flight-client" "$base" "$count" "$cert" > /dev/null 2>&1 &
ours=$!
"$programs/peer" $client_mode $((base + 2)) "$count" > /dev/null 2>&1 &
go_client=$!
(for ((i = 0; i < count; i++)); do timeout 1 openssl s_client -connect 127.0.0.1:$((base + 1)) $openssl_version -ign_eof < /dev/null > /dev/null 2>&1 || true; done) > /dev/null 2>&1 &
ossl=$!
wait "$ours" "$go_client" "$ossl" || true
sleep 1
for index in 0 1 2; do
    served=$(grep -c '^CASE' "$out/fs-$index.out" || true)
    [[ $served -eq $count ]] || echo "flight: the server on port $((base + index)) served $served of $count cases" >&2
done
paste -d' ' <(grep '^CASE' "$out/fs-0.out" | sort -k2,2n) <(grep '^CASE' "$out/fs-1.out" | sort -k2,2n | awk '{print $NF}') \
    <(grep '^CASE' "$out/fs-2.out" | sort -k2,2n | awk '{print $NF}') | awk '{print $2, $3, $4, $5, $6}' > "$out/flight.txt"
awk 'function cls(x) { if (x ~ /^F/) return "take"; if (x ~ /^A/ || x == "C") return "refuse"; return "wait" }
    { o = cls($3); s = cls($4); g = cls($5); key = o "/" s "/" g; n[key]++; if (!(key in first)) first[key] = $0
      if (o == "take" && s == "refuse" && g == "refuse") print "LENIENT", $0
      if (o == "refuse" && s == "take" && g == "take") print "STRICT", $0 }
    END { for (k in n) print "COUNT", k, n[k], "e.g.", first[k] }' "$out/flight.txt" | sort
