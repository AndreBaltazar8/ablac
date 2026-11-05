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

    # A deliberately leaky edit to tested SubWord code must reach the fixture.
    marker = '    aesStore(q, word)\n'
    assert source.count(marker) == 1
    leak = '    if (word.declassify() == u32(0)) ablaUnsafeVolatileStoreU8(q, 1)\n'
    (copied / aes).write_text(source.replace(marker, marker + leak))
    changed = run()
    assert changed.returncode == 0, changed.stderr
    generated = (copied / 'fixture.ab').read_text()
    assert leak in generated and generated != original, 'stale SubWord fixture'

    # Even a comment outside the tested stages requires an explicit review.
    marker = '    val words = count / 4\n'
    assert source.count(marker) == 1
    (copied / aes).write_text(source.replace(marker, '    // unreviewed scaffold\n' + marker))
    changed = run()
    assert changed.returncode != 0
    assert 'aesExpandBytes: excluded source changed' in changed.stderr

    # Orthogonalization now uses the actual imported helper: no fixture-only
    # substitution of its literal indices or arithmetic remains.
    assert 'aesOrthogonalize(' in original
    assert 'ctSourceOrthogonalize' not in original
print('ok   crypto fixture generation: source leak propagated, scaffold edit refused, actual orthogonalization imported')
