#!/usr/bin/env bash
# abla/http/h2 under seeded fuzzing (tools/http2-fuzz/fuzz.ab): HPACK round trips with changing table sizes, mutated valid blocks and random
# blocks, checking the decoder's limits, the table agreement and that a refusing decoder stays refusing. HTTP2_FUZZ_SEEDS sets how many runs
# (default 3000), HTTP2_FUZZ_FIRST the first seed (default 1).
set -euo pipefail
compiler=${1:-build/ablac}
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
out=build/http2-fuzz
rm -rf "$out"
mkdir -p "$out"
"$compiler" build tools/http2-fuzz/fuzz.ab -o "$out/fuzz" --no-cache > "$out/build.log" 2>&1 || { cat "$out/build.log" >&2; exit 1; }
first=${HTTP2_FUZZ_FIRST:-1}
seeds=${HTTP2_FUZZ_SEEDS:-3000}
if "$root/tools/run-limited.sh" "$out/fuzz" "$first" "$seeds" > "$out/fuzz.log" 2>&1; then
    echo "http2-fuzz ok: $(tail -1 "$out/fuzz.log")"
else
    tail -30 "$out/fuzz.log" >&2
    echo "http2-fuzz: FAILED" >&2
    exit 1
fi
