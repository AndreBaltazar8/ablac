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
client_program=cflight
[[ -n ${CFLIGHT_TLS12:-} ]] && client_program=cflight12   # CFLIGHT_TLS12=1: the TLS 1.2 client (tools/tls-diff/cflight12.ab); no client certificates
resume=${CFLIGHT_RESUME:-}   # CFLIGHT_RESUME=1: tools/tls-diff/cresume.ab resumes with changed tickets and binders against server-resume.ab (ours), s_server and Go
[[ -n $resume ]] && client_program=cresume
auth=${CFLIGHT_AUTH:-}   # CFLIGHT_AUTH=1: the servers require a client certificate (a CA and a client certificate are made in OUTDIR)
openssl_auth=()
ours_auth=()
go_auth=()
client_auth=()
if [[ -n $auth ]]; then
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$out/ca-k.pem" -out "$out/ca.pem" -subj /CN=clientca -days 2 2> /dev/null
    openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -keyout "$out/cl-k.pem" -out "$out/cl.csr" -subj /CN=client 2> /dev/null
    printf "keyUsage=digitalSignature\nextendedKeyUsage=clientAuth\n" > "$out/cl.ext"
    openssl x509 -req -in "$out/cl.csr" -CA "$out/ca.pem" -CAkey "$out/ca-k.pem" -CAcreateserial -out "$out/cl.pem" -days 2 -extfile "$out/cl.ext" 2> /dev/null
    openssl_auth=(-Verify 1 -CAfile "$out/ca.pem")
    ours_auth=("$out/ca.pem")
    go_auth=("$out/ca.pem")
    client_auth=("$out/cl.pem" "$out/cl-k.pem")
fi
pids=()
trap 'for p in "${pids[@]}"; do kill "$p" 2> /dev/null || true; done' EXIT
if [[ -n $resume ]]; then
    "$programs/server-resume" "$cert" "$key" "$base" > "$out/ours.log" 2>&1 &
else
    "$programs/server" "$cert" "$key" "$base" hold "${ours_auth[@]}" > "$out/ours.log" 2>&1 &
fi
pids+=("$!")
(sleep 3000 | openssl s_server -accept 127.0.0.1:$((base + 1)) -cert "$cert" -key "$key" -quiet -www "${openssl_auth[@]}") > "$out/openssl.log" 2>&1 &
pids+=("$!")
"$programs/peer" server $((base + 2)) "$cert" "$key" hold "${go_auth[@]}" > "$out/go.log" 2>&1 &
pids+=("$!")
for ((w = 0; w < 100; w++)); do
    grep -q listening "$out/ours.log" 2> /dev/null && grep -q listening "$out/go.log" 2> /dev/null && break
    sleep 0.1
done
sleep 1
for index in 0 1 2; do
    "$programs/$client_program" $((base + index)) "$seed" "$count" "${client_auth[@]}" > "$out/cf-$index.out" 2>&1 &
    pids+=("$!")
done
wait "${pids[@]:3}" || true
for index in 0 1 2; do
    served=$(grep -c '^CASE' "$out/cf-$index.out" || true)
    [[ $served -eq $count ]] || echo "cflight: the client for port $((base + index)) printed $served of $count cases" >&2
done
paste -d' ' <(grep '^CASE' "$out/cf-0.out" | sort -k2,2n) <(grep '^CASE' "$out/cf-1.out" | sort -k2,2n | awk '{print $NF}') \
    <(grep '^CASE' "$out/cf-2.out" | sort -k2,2n | awk '{print $NF}') | awk '{print $2, $3, $4, $5, $6}' > "$out/cflight.txt"
if [[ -n $resume ]]; then
    # Resumption: R = the ServerHello selected the PSK (ticket and binder were taken), anything else is not a resumption. LENIENT here is a forged or damaged
    # resumption that ours accepts and both others do not: read those first.
    awk 'function cls(x) { if (x ~ /^R\//) return "R"; return "n" }
        { o = cls($3); s = cls($4); g = cls($5); key = o "/" s "/" g; n[key]++; if (!(key in first)) first[key] = $0
          if (o == "R" && s == "n" && g == "n") print "LENIENT", $0
          if (o == "n" && s == "R" && g == "R") print "STRICT", $0 }
        END { for (k in n) print "COUNT", k, n[k], "e.g.", first[k] }' "$out/cflight.txt" | sort
    exit 0
fi
awk 'function cls(x) { if (x == "F/ok") return "take"; if (x ~ /^F\/A/ || x ~ /^F\/C/ || x ~ /^A/ || x == "C") return "refuse"; return "other" }
    { o = cls($3); s = cls($4); g = cls($5); key = o "/" s "/" g; n[key]++; if (!(key in first)) first[key] = $0
      if (o == "take" && s == "refuse" && g == "refuse") print "LENIENT", $0
      if (o == "refuse" && s == "take" && g == "take") print "STRICT", $0 }
    END { for (k in n) print "COUNT", k, n[k], "e.g.", first[k] }' "$out/cflight.txt" | sort
