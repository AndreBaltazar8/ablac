#!/usr/bin/env python3
"""Fail closed on unreviewed scaffolding; never check stale arithmetic copies."""
from pathlib import Path
import re
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
    # A call out of the region must be to a helper the checker reads or an intrinsic: a new call to an allocating
    # or opaque function inside it would otherwise be followed and fail only by accident.
    allowed = {'GF', 'aesDecLastRound', 'aesDecRound', 'aesEncLastRound', 'aesEncRound', 'aesInvMixColumns', 'aesLoad',
               'aesLoadBytes', 'aesOrthogonalize', 'aesStore', 'aesSubBytes', 'rotr', 'secretU32', 'storeAddress',
               'target', 'u32', 'u8x16LoadAddress'}
    defined = set(re.findall(r'\bfun (?:\w+\.)?(\w+)\(', region))
    outside = set(re.findall(r'\b([A-Za-z_]\w*)\(', region)) - defined - allowed
    assert not outside, f'the region calls {sorted(outside)}, which the fixtures do not read; list it or move it out'
    for name in ['aesKeyBytes', 'aesAllocateMemory', 'aesNewKey', 'aesStringAddress', 'aesExpandBytes']:
        assert f'fun {name}(' in source and f'fun {name}(' not in region, f'{name} must stay outside the region'

    # Even a comment in the allocation wrappers, which the checker does not read, requires an explicit review.
    # The same goes for the public entries that pick the addresses and rounds the read workers get.
    for marker in ['    val total = 4 * (count / 4 + 7)\n', '    aesHardwareDecryptAt(key.decryption(), key.rounds, input, output, count)']:
        assert source.count(marker) == 1, marker
        (copied / aes).write_text(source.replace(marker, '    // unreviewed scaffold\n' + marker, 1) if marker.startswith('    val')
                                  else source.replace(marker, marker.replace('key.decryption()', 'key.schedule()')))
        changed = run()
        assert changed.returncode != 0, marker
        assert 'aesWrappers: excluded source changed' in changed.stderr, marker
        (copied / aes).write_text(source)

    # Orthogonalization now uses the actual imported helper: no fixture-only
    # substitution of its literal indices or arithmetic remains.
    assert 'aesOrthogonalize(' in region
    assert 'ctSourceOrthogonalize' not in original and 'ctSourceOrthogonalize' not in region
print('ok   crypto fixture generation: the key functions lie in the region the fixtures read, a wrapper edit is refused, actual orthogonalization imported')
