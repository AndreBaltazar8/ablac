#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
cd "$root"
export ABLA_SYSROOT="$root"
out=build/gzip-inflate
mkdir -p "$out"
"$compiler" build tests/cases/gzip-inflate/main.ab -o "$out/check" --fast --no-cache
"$compiler" build tests/cases/gzip-inflate/invalid.ab -o "$out/invalid" --fast --no-cache
fixtures=tests/cases/gzip-inflate/fixtures
tools/verify-fixture-manifest.sh "$fixtures"
: > "$out/empty"
printf hello > "$out/optional.raw"
awk 'BEGIN { for (i = 0; i < 130000; i++) print "large compressed input 0123456789" }' > "$out/large"
for level in 0 1 6 9; do "$out/check" "$fixtures/raw" "$fixtures/level$level.gz"; done
for level in 1 6 9; do gzip -n -"$level" -c "$fixtures/raw" > "$out/system-$level.gz"; "$out/check" "$fixtures/raw" "$out/system-$level.gz"; done
gzip -n -6 -c "$out/large" > "$out/large.gz"
"$out/check" "$out/large" "$out/large.gz"
"$out/check" "$out/empty" "$fixtures/empty.gz"
"$out/check" "$out/optional.raw" "$fixtures/optional.gz"
for input in "$fixtures"/bad-*; do "$out/invalid" "$input"; done
"$out/check" "$fixtures/raw" "$fixtures/level6.gz" mutate
"$compiler" build tests/cases/gzip-inflate/build.ab -o "$out/build" --fast --no-cache
node --input-type=module - "$out/pure.wasm" <<'JS'
import {readFileSync} from 'node:fs';
const {instance} = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
if (Number(instance.exports.inflateCheck()) !== 42) process.exit(1);
JS
"$compiler" build tests/cases/gzip-inflate/pure.ab --target-triple xtensa-esp-unknown-elf --object-format elf --emit object -o "$out/xtensa.o" --fast --no-cache
printf '%s\n' 'gzip-inflate: levels, empty, mutations, hostless Wasm and Xtensa passed'
