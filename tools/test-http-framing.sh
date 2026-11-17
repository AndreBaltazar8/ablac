#!/usr/bin/env bash
# HTTP/1.1 request framing against Node's llhttp (tests/cases/http-framing): 237 raw request streams (request line, header
# name and value bytes, bare CR and LF, obs-fold, Content-Length and Transfer-Encoding in every combination, chunk sizes,
# extensions and trailers, pipelining, incomplete input, oversize heads) are framed the way the event server does it
# (httpEventFrame, request after request) and compared with what llhttp makes of the same bytes (oracle.mjs, recorded in
# llhttp.expected, from the Node of shell.nix, so the test also runs without node; another Node's llhttp may differ on a few streams and is then used instead). Abla may refuse more than llhttp; a stream on which it frames a
# request llhttp refuses, or frames it differently, must be listed in exceptions.txt with the reason, and a listed
# exception that no longer differs is an error. Ordinary code and # (interpreter, JIT) must agree and print cases.expected.
set -euo pipefail

compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_root"
cases=tests/cases/http-framing
out=build/http-framing
rm -rf "$out"
mkdir -p "$out"

for tier in interp jit; do
    ABLA_COMPILE_EVAL=$tier "$compiler" build "$cases/cases.ab" -o "$out/cases-$tier" --fast --no-cache
    set +e
    "$out/cases-$tier" > "$out/cases-$tier.txt" 2>&1
    status=$?
    set -e
    [[ $status -eq 0 ]] || { echo "http framing ($tier): run time and compile time differ:" >&2; grep -a '^DIFF' "$out/cases-$tier.txt" | head -10 >&2; exit 1; }
    if ! cmp -s "$cases/cases.expected" "$out/cases-$tier.txt"; then
        echo "http framing ($tier) differs from cases.expected:" >&2
        diff "$cases/cases.expected" "$out/cases-$tier.txt" | head -20 >&2
        exit 1
    fi
done
sed '1s/.*/mutated/' "$cases/cases.expected" > "$out/mutated.expected"
! cmp -s "$out/mutated.expected" "$out/cases-interp.txt" || { echo "http framing: the negative control matched" >&2; exit 1; }

node=${HTTP_FRAMING_NODE:-$(command -v node || true)}
llhttp="$cases/llhttp.expected"
if [[ -n $node ]]; then
    "$node" "$cases/gen.mjs" "$out/cases.ab"
    cmp -s "$out/cases.ab" "$cases/cases.ab" || { echo "http framing: cases.ab is not what gen.mjs makes from requests.mjs" >&2; exit 1; }
    "$node" "$cases/oracle.mjs" > "$out/llhttp.txt"
    cmp -s "$out/llhttp.txt" "$cases/llhttp.expected" || { echo "http framing: this Node's llhttp frames differently from llhttp.expected:" >&2; diff "$cases/llhttp.expected" "$out/llhttp.txt" | head -10 >&2; llhttp="$out/llhttp.txt"; }
fi
if [[ -z $node ]]; then
    echo "http framing: recorded results match; the comparison with llhttp is skipped (no node)"
    exit 0
fi
"$node" "$cases/compare.mjs" "$llhttp" "$out/cases-interp.txt" "$cases/exceptions.txt"
