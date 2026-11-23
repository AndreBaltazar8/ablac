#!/usr/bin/env bash
# The client-flight differential (#1139 area 3, TLS round 3): tools/tls-diff/cflight.ab sends COUNT changed client flights to each of three servers (ours,
# `openssl s_server`, Go crypto/tls) and prints, per connection, what each did. Usage: tools/tls-diff/cflight.sh OUTDIR PROGRAMS_DIR SEED COUNT [CERT KEY]
# PROGRAMS_DIR holds cflight, server (ours, tools/tls-diff/server.ab) and peer. The lines are the summary: LENIENT (ours takes what both others refuse), STRICT
# (ours refuses what both take), and COUNT per combination.
set -euo pipefail
out=$1 programs=$2 seed=$3 count=$4
mkdir -p "$out"
cert=${5:-$out/c.pem}
key=${6:-$out/k.pem}
if [[ ! -f $cert ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$key" -out "$cert" -subj /CN=localhost -addext subjectAltName=DNS:localhost -days 2 2> /dev/null
fi
base=${CFLIGHT_PORT:-29500}
pids=()
trap 'for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done' EXIT
"$programs/server" "$cert" "$key" "$base" hold > "$out/ours.log" 2>&1 &
pids+=("$!")
(sleep 3000 | openssl s_server -accept 127.0.0.1:$((base + 1)) -cert "$cert" -key "$key" -quiet -www) > "$out/openssl.log" 2>&1 &
pids+=("$!")
"$programs/peer" server $((base + 2)) "$cert" "$key" hold > "$out/go.log" 2>&1 &
pids+=("$!")
for ((w = 0; w < 100; w++)); do
    grep -q listening "$out/ours.log" 2> /dev/null && grep -q listening "$out/go.log" 2> /dev/null && break
    sleep 0.1
done
sleep 1
for index in 0 1 2; do
    "$programs/cflight" $((base + index)) "$seed" "$count" > "$out/cf-$index.out" 2>&1 &
    pids+=("$!")
done
wait "${pids[@]:3}" || true
for index in 0 1 2; do
    served=$(grep -c '^CASE' "$out/cf-$index.out" || true)
    [[ $served -eq $count ]] || echo "cflight: the client for port $((base + index)) printed $served of $count cases" >&2
done
paste -d' ' <(grep '^CASE' "$out/cf-0.out" | sort -k2,2n) <(grep '^CASE' "$out/cf-1.out" | sort -k2,2n | awk '{print $NF}') \
    <(grep '^CASE' "$out/cf-2.out" | sort -k2,2n | awk '{print $NF}') | awk '{print $2, $3, $4, $5, $6}' > "$out/cflight.txt"
awk 'function cls(x) { if (x == "F/ok") return "take"; if (x ~ /^F\/A/ || x ~ /^F\/C/ || x ~ /^A/ || x == "C") return "refuse"; return "other" }
    { o = cls($3); s = cls($4); g = cls($5); key = o "/" s "/" g; n[key]++; if (!(key in first)) first[key] = $0
      if (o == "take" && s == "refuse" && g == "refuse") print "LENIENT", $0
      if (o == "refuse" && s == "take" && g == "take") print "STRICT", $0 }
    END { for (k in n) print "COUNT", k, n[k], "e.g.", first[k] }' "$out/cflight.txt" | sort
