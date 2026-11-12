import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile

binary = Path(sys.argv[1]).resolve()
base = Path(sys.argv[2]).resolve()
base.mkdir(parents=True, exist_ok=True)
host = {'Linux': 'x86_64-linux', 'Darwin': {'arm64': 'arm64-macos', 'x86_64': 'x86_64-macos'}.get(platform.machine())}.get(platform.system())
assert host, (platform.system(), platform.machine())
version = '23.1.3-1'
tag = 'abla-xtensa-llvm-' + version
sha = lambda x: hashlib.sha256(x).hexdigest()

def fixture(name, helper):
    root = base / name
    (root / 'libexec').mkdir(parents=True)
    (root / 'libexec/ablac.bin').write_bytes(b'compiler')
    files = {'bin/opt': helper, 'bin/llc': helper, 'lib/libLLVM.test': b'private'}
    manifest = {'schema': 1, 'version': tag, 'platform': host, 'llvmVersion': '23.1.3', 'sourceCommit': 'a'*40, 'sourceArchiveSha256': 'b'*64, 'files': {k: sha(v) for k, v in files.items()}}
    manifest = (json.dumps(manifest, sort_keys=True, indent=2) + '\n').encode()
    stream = io.BytesIO()
    with tarfile.open(fileobj=stream, mode='w', format=tarfile.USTAR_FORMAT) as tar:
        for path, data in [*files.items(), ('manifest.json', manifest)]:
            info = tarfile.TarInfo(tag + '-' + host + '/' + path)
            info.size = len(data)
            info.mode = 0o755 if path.startswith('bin/') else 0o644
            tar.addfile(info, io.BytesIO(data))
    archive = gzip.compress(stream.getvalue(), mtime=0)
    archive_path = base / (name + '.tar.gz')
    archive_path.write_bytes(archive)
    platforms = {h: {'url': f'https://github.com/AndreBaltazar8/llvm-project/releases/download/{tag}/{tag}-{h}.tar.gz', 'sha256': sha(archive), 'manifestSha256': sha(manifest)} for h in ('x86_64-linux', 'arm64-macos', 'x86_64-macos')}
    catalog = {'schema': 1, 'releases': {version: {'status': 'published', 'llvmVersion': '23.1.3', 'sourceCommit': 'a'*40, 'sourceArchiveSha256': 'b'*64, 'platforms': platforms}}}
    catalog_path = base / (name + '.json')
    catalog_path.write_text(json.dumps(catalog))
    return root, archive_path, catalog_path

def run(root, catalog, *args, success=True):
    result = subprocess.run([str(binary), '--toolchain-root', str(root), '--catalog', str(catalog), *map(str, args)], capture_output=True, text=True, timeout=60)
    assert (result.returncode == 0) == success, (result.args, result.returncode, result.stdout, result.stderr)
    return result

assert subprocess.run([str(binary), '-h'], capture_output=True).returncode == 0
for flag in ('--verify=1', '--help=1'):
    assert subprocess.run([str(binary), flag], capture_output=True).returncode != 0

good = b"#!/bin/sh\nprintf '%s\\n' 'LLVM version 23.1.3' 'Registered Targets: xtensa'\n"
root, archive, catalog = fixture('good', good)
run(root, catalog, '--version', version, '--archive', archive)
parent = root / 'lib/abla/xtensa-llvm'
assert os.readlink(parent / 'current') == version
run(root, catalog, '--verify')
# The packaged entry is a symlink to libexec; root discovery must follow it.
(root / 'bin').mkdir()
shutil.copy2(binary, root / 'libexec/abla-install-xtensa-native')
(root / 'bin/abla-install-xtensa-native').symlink_to('../libexec/abla-install-xtensa-native')
result = subprocess.run([str(root / 'bin/abla-install-xtensa-native'), '--catalog', str(catalog), '--verify'], capture_output=True, text=True, timeout=60)
assert result.returncode == 0, (result.stdout, result.stderr)
external = base / 'external-bin'
external.mkdir()
(external / 'installer').symlink_to(root / 'bin/abla-install-xtensa-native')
result = subprocess.run([str(external / 'installer'), '--catalog', str(catalog), '--verify'], capture_output=True, text=True, timeout=60)
assert result.returncode == 0, (result.stdout, result.stderr)
result = subprocess.run([str(root / 'bin/abla-install-xtensa-native'), '--catalog=' + str(catalog), '--verify'], capture_output=True, text=True, timeout=60)
assert result.returncode == 0, (result.stdout, result.stderr)
run(root, catalog, '--version', version, '--archive', base / 'missing')
assert os.readlink(parent / 'current') == version
# A 0700 published root is incomplete: neither verification nor installation
# may accept it or change the active link.
(parent / 'current').unlink()
(parent / 'current').symlink_to('old')
(parent / version).chmod(0o700)
for args in (('--verify', '--version', version), ('--version', version, '--archive', archive)):
    result = run(root, catalog, *args, success=False)
    assert 'publication_in_progress' in result.stderr, result.stderr
    assert os.readlink(parent / 'current') == 'old'
(parent / version).chmod(0o555)
(parent / 'current').unlink()
(parent / 'current').symlink_to(version)
# A validly pinned archive with a failing helper must not publish or activate.
badroot, badarchive, badcatalog = fixture('bad-helper', b'#!/bin/sh\nexit 1\n')
badparent = badroot / 'lib/abla/xtensa-llvm'
badparent.mkdir(parents=True)
(badparent / 'current').symlink_to('old')
result = run(badroot, badcatalog, '--version', version, '--archive', badarchive, success=False)
assert 'helper exit' in result.stderr, result.stderr
assert os.readlink(badparent / 'current') == 'old'
assert sorted(p.name for p in badparent.iterdir()) == ['current']
# A corrupted archive fails the pin before decompression or activation.
hashroot, hasharchive, hashcatalog = fixture('bad-hash', good)
hasharchive.write_bytes(hasharchive.read_bytes() + b'x')
result = run(hashroot, hashcatalog, '--version', version, '--archive', hasharchive, success=False)
assert 'archive_hash' in result.stderr, result.stderr
assert not (hashroot / 'lib/abla/xtensa-llvm/current').exists()
run(root, catalog, '--verify', '--archive', archive, success=False)
print('native Xtensa installer: install, verify, activation and rollback passed')
