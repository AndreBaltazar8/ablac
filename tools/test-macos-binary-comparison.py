#!/usr/bin/env python3
"""Check exact-match and metadata/code mismatch controls on a real Mach-O asset."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile

spec = importlib.util.spec_from_file_location('macho_comparison', Path(__file__).with_name('compare-macos-binaries.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
source = Path(sys.argv[1]).absolute()
original, inventory = module.inventory(source)
with tempfile.TemporaryDirectory(prefix='abla-macos-compare-') as temporary:
    root = Path(temporary)
    with contextlib.redirect_stdout(io.StringIO()):
        assert module.compare(source, source, root / 'exact') == 0
    uuid = next(command for command in inventory['loadCommands'] if command['command'] == '0x1b')
    text = next(section for section in inventory['sections'] if section['name'] == '__TEXT,__text')
    controls = [('uuid', uuid['offset'] + 8, 'load command'), ('code', text['offset'], 'section')]
    signature = next((command for command in inventory['loadCommands'] if command['command'] == '0x1d'), None)
    if signature:
        controls.append(('signature', signature['fileData']['offset'] + signature['fileData']['bytes'] - 1, 'link-edit data'))
    for label, offset, region in controls:
        data = bytearray(original)
        data[offset] ^= 1
        changed = root / (label + '.macho')
        changed.write_bytes(data)
        with contextlib.redirect_stdout(io.StringIO()):
            assert module.compare(source, changed, root / label) == 1
        report = json.loads((root / label / 'comparison.json').read_text())
        assert not report['rawEqual'] and report['cmpStatus'] == 1
        assert report['firstDifferentByte'] == offset
        assert report['publishedLocation']['region'] == region, report
        if label == 'code':
            assert any(row['name'] == '__TEXT,__text' for row in report['differentSections'])
        else:
            assert report['differentFunctionCount'] == 0
        print(f'Mach-O comparator: rejects {label} mutation at {offset}', flush=True)
assert source.read_bytes() == original
print('Mach-O comparator: exact match and all deliberate mismatches passed')
