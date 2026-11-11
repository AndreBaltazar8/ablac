#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${1:-$root/build/ablac}
cd "$root"
export ABLA_SYSROOT="$root"
out=build/tar-reader
rm -rf "$out"
mkdir -p "$out/tree/root/sub"
printf 'payload\n' > "$out/tree/root/file.txt"
printf 'nested\n' > "$out/tree/root/sub/nested.txt"
"$compiler" build tests/cases/tar-reader/probe.ab -o "$out/probe" --fast --no-cache
"$compiler" build tests/cases/tar-reader/companion.ab -o "$out/companion" --fast --no-cache
tar --format=ustar -cf "$out/gnu-ustar.tar" -C "$out/tree" root
python3 - "$out" <<'PY'
import io, os, sys, tarfile
p=sys.argv[1]
# The publisher's build.py uses tarfile.open(fileobj=zipped, mode="w").
from pathlib import Path
root=Path(p+'/tree/root')
with tarfile.open(p+'/publisher.tar', 'w') as t:
    for path in [root, *sorted(root.rglob('*'))]:
        entry=t.gettarinfo(str(path),arcname=str(path.relative_to(root.parent)))
        entry.uid=entry.gid=entry.mtime=0
        entry.uname=entry.gname=''
        entry.mode=0o755 if path.is_dir() or os.access(path,os.X_OK) else 0o644
        if path.is_file():
            with path.open('rb') as stream: t.addfile(entry,stream)
        else: t.addfile(entry)

def make(name, path='root/file.txt', kind=tarfile.REGTYPE, fmt=tarfile.USTAR_FORMAT, data=b'payload\n'):
    with tarfile.open(p+'/'+name+'.tar','w',format=fmt) as t:
        info=tarfile.TarInfo(path); info.type=kind
        if kind==tarfile.SYMTYPE: info.linkname='file.txt'; info.size=0
        else: info.size=len(data)
        t.addfile(info,io.BytesIO(data) if info.size else None)
make('pax','root/'+'x'*130,fmt=tarfile.PAX_FORMAT)
make('gnu-long','root/'+'x'*130,fmt=tarfile.GNU_FORMAT)
make('symlink','root/link',kind=tarfile.SYMTYPE)
make('absolute','/etc/passwd')
make('traversal','root/../escape')
with tarfile.open(p+'/duplicate.tar','w',format=tarfile.USTAR_FORMAT) as t:
    for _ in range(2):
        info=tarfile.TarInfo('same'); info.size=1; t.addfile(info,io.BytesIO(b'x'))
for name, paths in [('ancestor-first', ['a', 'a/b']), ('ancestor-last', ['a/b', 'a'])]:
    with tarfile.open(p+'/'+name+'.tar','w',format=tarfile.USTAR_FORMAT) as t:
        for path in paths:
            info=tarfile.TarInfo(path); info.size=1; t.addfile(info,io.BytesIO(b'x'))
good=open(p+'/gnu-ustar.tar','rb').read()
open(p+'/bad-checksum.tar','wb').write(bytes([good[0]^1])+good[1:])
open(p+'/bad-trailing.tar','wb').write(good+b'X'+bytes(511))
open(p+'/bad-truncated.tar','wb').write(good[:100])
PY
"$out/probe" "$out/gnu-ustar.tar" '' verify
"$out/probe" "$out/publisher.tar" '' verify
for test in pax gnu-long symlink; do "$out/probe" "$out/$test.tar" unsupported; done
for test in absolute traversal duplicate ancestor-first ancestor-last bad-checksum bad-trailing bad-truncated; do "$out/probe" "$out/$test.tar" invalid; done
"$out/probe" "$out/gnu-ustar.tar" '' mutate
"$compiler" build tests/cases/tar-reader/build.ab -o "$out/build" --fast --no-cache
node --input-type=module - "$out/pure.wasm" <<'JS'
import {readFileSync} from 'node:fs';
const {instance} = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
if (Number(instance.exports.tarCheck()) !== 42) process.exit(1);
JS
"$compiler" build tests/cases/tar-reader/pure.ab --target-triple xtensa-esp-unknown-elf --object-format elf --emit object -o "$out/xtensa.o" --fast --no-cache
if [[ -n ${ABLA_TEST_XTENSA_COMPANION:-} && -f $ABLA_TEST_XTENSA_COMPANION ]]; then
    "$out/companion" "$ABLA_TEST_XTENSA_COMPANION"
    echo 'tar-reader: cached Linux companion gzip + tar passed'
else
    echo 'tar-reader: cached Linux companion absent; gzip + tar check skipped'
fi
echo 'tar-reader: ustar, rejection, mutations, hostless Wasm and Xtensa passed'
