#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
cd "$root"
export ABLA_SYSROOT="$root"
out=build/tar-stream
mkdir -p "$out"
fixtures=tests/cases/tar-stream/fixtures
tools/verify-fixture-manifest.sh "$fixtures"
"$compiler" build tests/cases/tar-stream/main.ab -o "$out/test" --fast --no-cache
"$compiler" build tests/cases/tar-stream/gzip.ab -o "$out/gzip" --fast --no-cache
"$compiler" build tests/cases/tar-stream/limits.ab -o "$out/limits" --fast --no-cache
"$out/limits" "$fixtures/good.tar"
for fixture in good pax gnu symlink escape duplicate ancestor-first ancestor-last trailing truncated; do
    "$out/test" "$fixtures/$fixture.tar"
done
"$out/test" "$fixtures/good.tar" mutate
"$out/gzip" "$fixtures/good.tar.gz"
"$compiler" build tests/cases/tar-stream/build.ab -o "$out/build" --fast --no-cache
node --input-type=module - "$out/pure.wasm" <<'JS'
import {readFileSync} from 'node:fs';
const {instance} = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
if (Number(instance.exports.tarStreamCheck()) !== 42) process.exit(1);
JS
"$compiler" build tests/cases/tar-stream/pure.ab --target-triple xtensa-esp-unknown-elf --object-format elf --emit object -o "$out/xtensa.o" --fast --no-cache
echo 'tar-stream: chunk boundaries, parity, mutations, gzip, Wasm and Xtensa passed'
