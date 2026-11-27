#!/usr/bin/env bash
# #1139 area 4 round 8: the HTTP/2 HPACK decoder (stdlib/abla/http/h2/hpack) against Go's golang.org/x/net/http2/hpack on generated header block
# sequences (tools/fuzz/hpack-differential): indexed and literal fields of each kind, table size updates (in range, past the advertised 4096, after a
# field), huffman strings with flipped bits, an extra padding byte or EOS, overlong integers and cut blocks, the dynamic table carried across a
# case's blocks. A block Abla decodes when Go refuses it, or decodes to other fields, fails; one Abla refuses and Go takes is counted (stricter).
# Run by hand (not in the suite): it needs go and x/net v0.62.0 in the module cache (GOPROXY=off); without them it says so.
# Usage: tools/test-hpack-differential.sh [compiler] [seeds] [count]
set -euo pipefail
compiler=${1:-build/ablac}
seeds=${2:-1-8}
count=${3:-20000}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
tool=tools/fuzz/hpack-differential
out=build/hpack-differential
rm -rf "$out"
mkdir -p "$out"
command -v go > /dev/null || { echo 'hpack-differential: skipped (no go)'; exit 0; }
(cd "$tool/oracle" && GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off go build -o "$root/$out/oracle" .) > "$out/oracle.log" 2>&1 ||
    { echo 'hpack-differential: skipped (the Go oracle did not build: x/net v0.62.0 not in the module cache?)'; cat "$out/oracle.log"; exit 0; }
"$compiler" build "$tool/decode.ab" -o "$out/decode" --no-cache > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
first=${seeds%-*} last=${seeds#*-}
total=0
for ((seed = first; seed <= last; seed++)); do
    "$out/oracle" gen "$seed" "$count" > "$out/cases.txt"
    "$out/oracle" < "$out/cases.txt" > "$out/go.txt"
    "$out/decode" < "$out/cases.txt" > "$out/abla.txt"
    paste -d'\t' "$out/cases.txt" "$out/go.txt" "$out/abla.txt" | awk -f "$tool/classify.awk" > "$out/kinds-$seed.txt" 2> "$out/findings-$seed.txt"
    total=$((total + count))
    if [[ -s $out/findings-$seed.txt ]]; then
        head -5 "$out/findings-$seed.txt" >&2
        echo "hpack-differential: seed $seed: $(wc -l < "$out/findings-$seed.txt") sequences where Abla is looser than Go or decodes other fields" >&2
        exit 1
    fi
done
echo "hpack-differential: $total sequences (seeds $seeds): no block Abla decodes differently from Go's x/net hpack ($(cat "$out"/kinds-*.txt | awk '$1 == "stricter" { s += $2 } END { print s + 0 }') stricter)"
