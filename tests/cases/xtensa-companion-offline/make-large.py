#!/usr/bin/env python3
"""Create a controlled archive whose compressed size exceeds the old 128 MiB cap."""
import gzip
import hashlib
import io
import json
from pathlib import Path
import sys
import tarfile

out = Path(sys.argv[1])
size = 129 * 1024 * 1024
block = b'x' * 65536
large_hash = hashlib.sha256()
for _ in range(size // len(block)):
    large_hash.update(block)
files = {'bin/opt': b'opt', 'bin/llc': b'llc'}
manifest = {'schema': 1, 'version': 'abla-xtensa-llvm-23.1.3-1', 'platform': 'x86_64-linux',
            'llvmVersion': '23.1.3', 'sourceCommit': 'a' * 40, 'sourceArchiveSha256': 'b' * 64,
            'files': {name: hashlib.sha256(data).hexdigest() for name, data in files.items()}}
manifest['files']['lib/libLLVM.test'] = large_hash.hexdigest()
raw = (json.dumps(manifest, sort_keys=True) + '\n').encode()
prefix = 'abla-xtensa-llvm-23.1.3-1-x86_64-linux/'

class Repeated:
    def __init__(self, remaining): self.remaining = remaining
    def read(self, maximum):
        amount = min(maximum, self.remaining)
        self.remaining -= amount
        return b'x' * amount

archive = out / 'large.tar.gz'
with gzip.open(archive, 'wb', compresslevel=0) as compressed:
    with tarfile.open(fileobj=compressed, mode='w|', format=tarfile.USTAR_FORMAT) as tar:
        for name, data in [*files.items(), ('manifest.json', raw)]:
            info = tarfile.TarInfo(prefix + name)
            info.size = len(data)
            info.mode = 0o755 if name.startswith('bin/') else 0o644
            tar.addfile(info, io.BytesIO(data))
        info = tarfile.TarInfo(prefix + 'lib/libLLVM.test')
        info.size, info.mode = size, 0o644
        tar.addfile(info, Repeated(size))
hash_stream = hashlib.sha256()
with archive.open('rb') as source:
    while data := source.read(65536): hash_stream.update(data)
assert archive.stat().st_size > 128 * 1024 * 1024
pins = {'version': '23.1.3-1', 'platform': 'x86_64-linux', 'llvmVersion': '23.1.3',
        'sourceCommit': 'a' * 40, 'sourceArchiveSha256': 'b' * 64,
        'archiveSha256': hash_stream.hexdigest(), 'manifestSha256': hashlib.sha256(raw).hexdigest()}
(out / 'large.json').write_text(json.dumps(pins))
