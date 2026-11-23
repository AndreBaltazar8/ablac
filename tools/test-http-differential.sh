#!/usr/bin/env bash
# HTTP/1 request framing against llhttp on generated streams (#1139 area 4; tools/fuzz/http-differential). Streams from a grammar of
# framing variants (Content-Length and Transfer-Encoding spellings, lists and folds, line endings, chunk sizes, extensions and trailers,
# a marker request after each) with byte mutations are framed the way the event servers do (httpEventFrame) and by Node's llhttp:
# any stream on which the first request ends in another place or reads another body, or on which Abla frames a request llhttp refuses
# for a reason that is not one of the documented differences (compare.mjs), fails. The same streams read in pieces of 1 to 9 bytes
# through the chunked-request state must give the verdict of the whole stream. Needs node (shell.nix has it); without it the test says so.
# Usage: tools/test-http-differential.sh [compiler]
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
node=${HTTP_DIFFERENTIAL_NODE:-$(command -v node || true)}
if [[ -z $node ]]; then
    echo "http-differential: skipped (no node: llhttp is the reference)"
    exit 0
fi
tool=tools/fuzz/http-differential
out=build/http-differential
rm -rf "$out"
mkdir -p "$out"
"$compiler" build "$tool/framing.ab" -o "$out/framing" --fast --no-cache > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
for seed in 1 2 3; do
    "$node" "$tool/gen.mjs" "$seed" 4000 > "$out/cases.tsv"
    "$node" "$tool/oracle-llhttp.mjs" "$out/cases.tsv" > "$out/llhttp.tsv"
    "$out/framing" "$out/cases.tsv" > "$out/whole.tsv"
    "$out/framing" "$out/cases.tsv" --split > "$out/split.tsv"
    "$node" "$tool/compare.mjs" "$out/cases.tsv" "$out/llhttp.tsv" "$out/whole.tsv" --known --show 5 > "$out/llhttp.txt" 2>&1 || { cat "$out/llhttp.txt" >&2; echo "http-differential: seed $seed differs from llhttp" >&2; exit 1; }
    "$node" "$tool/compare.mjs" "$out/cases.tsv" "$out/whole.tsv" "$out/split.tsv" --show 5 > "$out/split.txt" 2>&1 || { cat "$out/split.txt" >&2; echo "http-differential: seed $seed: reading in pieces differs from reading the whole stream" >&2; exit 1; }
    grep -q '^12000 streams\|^4000 streams' "$out/llhttp.txt" || { cat "$out/llhttp.txt" >&2; echo "http-differential: no summary line" >&2; exit 1; }
done
echo "http-differential: 12000 generated streams agree with llhttp apart from the documented differences, and with themselves read in pieces"
