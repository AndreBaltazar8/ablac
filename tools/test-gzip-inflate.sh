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
python3 - "$out" <<'PY'
import gzip, os, random, sys, zlib
p=sys.argv[1]
r=random.Random(325)
raw=bytes(r.randrange(256) for _ in range(2048)) + b'abcde'*900
open(p+'/raw','wb').write(raw)
for level in [0,1,6,9]:
    open(p+'/level%d.gz'%level,'wb').write(gzip.compress(raw,compresslevel=level,mtime=0))
open(p+'/empty','wb').write(b'')
open(p+'/empty.gz','wb').write(gzip.compress(b'',mtime=0))
valid=gzip.compress(b'hello',mtime=0)
def bad(name, data): open(p+'/bad-'+name,'wb').write(data)
bad('magic', b'X'+valid[1:])
bad('flags', valid[:3]+b'\x80'+valid[4:])
bad('type', valid[:10]+b'\x07'+valid[11:])
bad('crc', valid[:-8]+bytes([valid[-8]^1])+valid[-7:])
bad('isize', valid[:-1]+bytes([valid[-1]^1]))
bad('truncated', valid[:-1])
bad('stored-length', valid[:10]+b'\x01\x01\x00\x00\x00A'+valid[-8:])
# BFINAL=1, BTYPE=2, HLIT=257, HDIST=1, HCLEN=4, four 1-bit code lengths: oversubscribed.
bits=[1,0,1]+[0]*14+[1,0,0]*4
body=bytes(sum((bits[j+i] if j+i<len(bits) else 0)<<i for i in range(8)) for j in range(0,len(bits),8))
bad('oversubscribed', valid[:10]+body+valid[-8:])
bits=[1,1,0]+[0,0,0,0,0,0,1]+[0]*5+[0]*7
body=bytes(sum((bits[j+i] if j+i<len(bits) else 0)<<i for i in range(8)) for j in range(0,len(bits),8))
bad('distance-before-start', valid[:10]+body+valid[-8:])
bad('header-crc', valid[:3]+b'\x02'+valid[4:10]+b'\x00\x00'+valid[10:])
optional=valid[:3]+b'\x1e'+valid[4:10]+b'\x03\x00abc'+b'name\x00comment\x00'
optional += (zlib.crc32(optional)&65535).to_bytes(2,'little')
open(p+'/optional.gz','wb').write(optional+valid[10:])
open(p+'/optional.raw','wb').write(b'hello')
open(p+'/large','wb').write((b'large compressed input 0123456789\n'*130000))
PY
for level in 0 1 6 9; do "$out/check" "$out/raw" "$out/level$level.gz"; done
for level in 1 6 9; do gzip -n -"$level" -c "$out/raw" > "$out/system-$level.gz"; "$out/check" "$out/raw" "$out/system-$level.gz"; done
gzip -n -6 -c "$out/large" > "$out/large.gz"
"$out/check" "$out/large" "$out/large.gz"
"$out/check" "$out/empty" "$out/empty.gz"
"$out/check" "$out/optional.raw" "$out/optional.gz"
for input in "$out"/bad-*; do "$out/invalid" "$input"; done
"$out/check" "$out/raw" "$out/level6.gz" mutate
"$compiler" build tests/cases/gzip-inflate/build.ab -o "$out/build" --fast --no-cache
node --input-type=module - "$out/pure.wasm" <<'JS'
import {readFileSync} from 'node:fs';
const {instance} = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
if (Number(instance.exports.inflateCheck()) !== 42) process.exit(1);
JS
"$compiler" build tests/cases/gzip-inflate/pure.ab --target-triple xtensa-esp-unknown-elf --object-format elf --emit object -o "$out/xtensa.o" --fast --no-cache
printf '%s\n' 'gzip-inflate: levels, empty, mutations, hostless Wasm and Xtensa passed'
