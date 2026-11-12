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
python3 - "$out" <<'PY'
import gzip, os, random, sys, zlib
p=sys.argv[1]
r=random.Random(793)
raw=bytes(r.randrange(256) for _ in range(256)) + b'abcde'*100
open(p+'/raw','wb').write(raw)
for level in (0,1,6,9):
    open(f'{p}/level{level}.gz','wb').write(gzip.compress(raw,compresslevel=level,mtime=0))
c=zlib.compressobj(6,zlib.DEFLATED,31,strategy=zlib.Z_FIXED)
open(p+'/fixed.gz','wb').write(c.compress(raw)+c.flush())
valid=gzip.compress(raw,mtime=0)
optional=valid[:3]+b'\x1e'+valid[4:10]+b'\x03\x00abc'+b'name\x00comment\x00'
optional += (zlib.crc32(optional)&65535).to_bytes(2,'little')
open(p+'/optional.gz','wb').write(optional+valid[10:])
long_raw=(b'window wrap 0123456789 abcdefghijklmnopqrstuvwxyz\n'*1500)
open(p+'/long','wb').write(long_raw)
open(p+'/long.gz','wb').write(gzip.compress(long_raw,mtime=0))
repeat_raw=b'Z'*75000
open(p+'/repeat','wb').write(repeat_raw)
open(p+'/repeat.gz','wb').write(gzip.compress(repeat_raw,mtime=0))
open(p+'/bad-magic','wb').write(b'X'+valid[1:])
open(p+'/bad-type','wb').write(valid[:10]+b'\x07'+valid[11:])
open(p+'/bad-isize','wb').write(valid[:-1]+bytes([valid[-1]^1]))
open(p+'/empty','wb').write(b'')
open(p+'/empty.gz','wb').write(gzip.compress(b'',mtime=0))
PY
for input in "$out"/level*.gz "$out/fixed.gz"; do "$out/check" "$out/raw" "$input"; done
"$out/check" "$out/raw" "$out/optional.gz"
"$out/check" "$out/raw" "$out/optional.gz" truncations
"$out/check" "$out/long" "$out/long.gz" long
"$out/check" "$out/repeat" "$out/repeat.gz" long
"$out/check" "$out/empty" "$out/empty.gz"
for input in "$out"/bad-*; do "$out/check" "$out/raw" "$input" invalid; done
"$compiler" build tests/cases/gzip-stream/build.ab -o "$out/build" --fast --no-cache
node --input-type=module - "$out/pure.wasm" <<'JS'
import {readFileSync} from 'node:fs';
const {instance} = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
if (Number(instance.exports.streamCheck()) !== 42) process.exit(1);
JS
"$compiler" build tests/cases/gzip-stream/pure.ab --target-triple xtensa-esp-unknown-elf --object-format elf --emit object -o "$out/xtensa.o" --fast --no-cache
printf '%s\n' 'gzip-stream: bounded input and output chunks, limits, trailer and source errors passed'
