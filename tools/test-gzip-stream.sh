#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
cd "$root"
export ABLA_SYSROOT="$root"
out=build/gzip-stream
mkdir -p "$out"
"$compiler" build tests/cases/gzip-stream/main.ab -o "$out/check" --fast --no-cache
"$compiler" build tests/cases/gzip-stream/resource.ab -o "$out/resource" --fast --no-cache
"$out/resource"
for mode in interp jit; do
    ABLA_COMPILE_EVAL=$mode "$compiler" build tests/cases/gzip-stream/staged.ab -o "$out/staged-$mode" --fast --no-cache
    "$out/staged-$mode"
done
if [[ $(uname -s) == Linux ]]; then
    "$compiler" build tests/cases/gzip-stream/drop.ab -o "$out/drop" --fast --no-cache
    (ulimit -v 196608; "$out/drop")
fi
fixtures=tests/cases/gzip-stream/fixtures
tools/verify-fixture-manifest.sh "$fixtures"
awk 'BEGIN { for (i = 0; i < 1500; i++) print "window wrap 0123456789 abcdefghijklmnopqrstuvwxyz" }' > "$out/long"
awk 'BEGIN { for (i = 0; i < 75000; i++) printf "Z" }' > "$out/repeat"
: > "$out/empty"
for input in "$fixtures"/level*.gz "$fixtures/fixed.gz"; do "$out/check" "$fixtures/raw" "$input"; done
"$out/check" "$fixtures/raw" "$fixtures/optional.gz"
"$out/check" "$fixtures/raw" "$fixtures/optional.gz" truncations
"$out/check" "$out/long" "$fixtures/long.gz" long
"$out/check" "$out/repeat" "$fixtures/repeat.gz" long
"$out/check" "$out/empty" "$fixtures/empty.gz"
for input in "$fixtures"/bad-*; do "$out/check" "$fixtures/raw" "$input" invalid; done
"$compiler" build tests/cases/gzip-stream/build.ab -o "$out/build" --fast --no-cache
node --input-type=module - "$out/pure.wasm" <<'JS'
import {readFileSync} from 'node:fs';
const {instance} = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
if (Number(instance.exports.streamCheck()) !== 42) process.exit(1);
JS
"$compiler" build tests/cases/gzip-stream/pure.ab --target-triple xtensa-esp-unknown-elf --object-format elf --emit object -o "$out/xtensa.o" --fast --no-cache
printf '%s\n' 'gzip-stream: bounded input and output chunks, limits, trailer and source errors passed'
