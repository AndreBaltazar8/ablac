#!/usr/bin/env python3
"""Fail closed on unreviewed scaffolding; never check stale arithmetic copies."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[2]
generator = Path('tests/cases/ct/crypto-source-fixtures.py')
aes = Path('stdlib/abla/crypto/aes/entry.ab')
with tempfile.TemporaryDirectory(prefix='abla-ct-source-') as directory:
    copied = Path(directory)
    for file in [generator, aes, Path('stdlib/abla/crypto/bignum/entry.ab'),
                 Path('stdlib/abla/crypto/rsa/entry.ab')]:
        target = copied / file
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(root / file, target)
    def run():
        return subprocess.run([sys.executable, str(copied / generator), str(copied / 'fixture.ab')],
                              capture_output=True, text=True)
    baseline = run()
    assert baseline.returncode == 0, baseline.stderr
    original = (copied / 'fixture.ab').read_text()
    source = (copied / aes).read_text()

    # What touches a key is read from the production source itself: the region between BEGIN/END AES KEY EXPANSION is
    # appended to the fixture module by tools/test-ct.sh, so every function the fixtures call must lie inside it.
    begin, end = source.index('// BEGIN AES KEY EXPANSION\n'), source.index('// END AES KEY EXPANSION\n')
    assert source.count('// BEGIN AES KEY EXPANSION\n') == source.count('// END AES KEY EXPANSION\n') == 1
    region = source[begin:end]
    for name in ['aesExpandSchedule', 'aesSubWord', 'aesDecryptionKeys', 'aesHardwareEncryptAt', 'aesHardwareDecryptAt']:
        assert f'fun {name}(' in region, f'{name} is outside the region the fixtures read'
        assert name == 'aesSubWord' or f'{name}(' in original, f'no fixture calls {name}'
    for name in ['aesAllocateMemory', 'aesNewKey', 'aesStringAddress', 'aesExpandBytes']:
        assert f'fun {name}(' in source and f'fun {name}(' not in region, f'{name} must stay outside the region'

    # Even a comment in the allocation wrappers, which the checker does not read, requires an explicit review.
    marker = '    val words = count / 4\n'
    assert source.count(marker) >= 2
    (copied / aes).write_text(source.replace(marker, '    // unreviewed scaffold\n' + marker, 1))
    changed = run()
    assert changed.returncode != 0
    assert 'aesWrappers: excluded source changed' in changed.stderr
    (copied / aes).write_text(source)

    # Orthogonalization now uses the actual imported helper: no fixture-only
    # substitution of its literal indices or arithmetic remains.
    assert 'aesOrthogonalize(' in region
    assert 'ctSourceOrthogonalize' not in original and 'ctSourceOrthogonalize' not in region
print('ok   crypto fixture generation: the key functions lie in the region the fixtures read, a wrapper edit is refused, actual orthogonalization imported')
