#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
cd "$root"
export ABLA_SYSROOT="$root"
out=build/tar-stream
mkdir -p "$out"
python3 - "$out" <<'PY'
import gzip, io, sys, tarfile
from pathlib import Path
p=Path(sys.argv[1])
with tarfile.open(p/'good.tar', 'w', format=tarfile.USTAR_FORMAT) as t:
    for name,data in [('root/file',b'first file'),('root/other',b'x'*1027)]:
        info=tarfile.TarInfo(name); info.size=len(data); info.mode=0o644
        t.addfile(info,io.BytesIO(data))
good=(p/'good.tar').read_bytes()
with gzip.open(p/'good.tar.gz','wb') as f: f.write(good)
for name,path,kind,fmt in [('pax','x'*130,tarfile.REGTYPE,tarfile.PAX_FORMAT),
                           ('gnu','x'*130,tarfile.REGTYPE,tarfile.GNU_FORMAT),
                           ('symlink','link',tarfile.SYMTYPE,tarfile.USTAR_FORMAT),
                           ('escape','../bad',tarfile.REGTYPE,tarfile.USTAR_FORMAT)]:
    with tarfile.open(p/(name+'.tar'),'w',format=fmt) as t:
        info=tarfile.TarInfo(path); info.type=kind; info.linkname='target'
        t.addfile(info)
for name,paths in [('duplicate',['a','a']),('ancestor-first',['a','a/b']),('ancestor-last',['a/b','a'])]:
    with tarfile.open(p/(name+'.tar'),'w',format=tarfile.USTAR_FORMAT) as t:
        for path in paths:
            info=tarfile.TarInfo(path); info.size=1; t.addfile(info,io.BytesIO(b'x'))
(p/'trailing.tar').write_bytes(good+b'X'+bytes(511))
(p/'truncated.tar').write_bytes(good[:513])
PY
"$compiler" build tests/cases/tar-stream/main.ab -o "$out/test" --fast --no-cache
"$compiler" build tests/cases/tar-stream/gzip.ab -o "$out/gzip" --fast --no-cache
"$compiler" build tests/cases/tar-stream/limits.ab -o "$out/limits" --fast --no-cache
"$out/limits" "$out/good.tar"
for fixture in good pax gnu symlink escape duplicate ancestor-first ancestor-last trailing truncated; do
    "$out/test" "$out/$fixture.tar"
done
"$out/test" "$out/good.tar" mutate
"$out/gzip" "$out/good.tar.gz"
"$compiler" build tests/cases/tar-stream/build.ab -o "$out/build" --fast --no-cache
node --input-type=module - "$out/pure.wasm" <<'JS'
import {readFileSync} from 'node:fs';
const {instance} = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
if (Number(instance.exports.tarStreamCheck()) !== 42) process.exit(1);
JS
"$compiler" build tests/cases/tar-stream/pure.ab --target-triple xtensa-esp-unknown-elf --object-format elf --emit object -o "$out/xtensa.o" --fast --no-cache
echo 'tar-stream: chunk boundaries, parity, mutations, gzip, Wasm and Xtensa passed'
