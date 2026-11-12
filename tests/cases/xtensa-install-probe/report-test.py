#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
reporter = root / 'tools/report-xtensa-install-probe.py'
release = (root / '.github/workflows/release.yml').read_text()
ci = (root / '.github/workflows/ci.yml').read_text()
release_start = release.index('        run: |\n', release.index('        name: Install the native toolchain'))
release_end = release.index('      - name: Prepare the bootstrap compiler', release_start)
probe_start = ci.index('        run: |\n', ci.index('      - name: Install native build dependencies on macOS'))
probe_end = ci.index('      - name: Install native build dependencies on Linux', probe_start)
release_setup = release[release_start:release_end].replace(
    "'${{ matrix.architecture }}' == x86_64", "'${{ matrix.platform }}' == x86_64-macos")
probe_setup = ci[probe_start:probe_end]
assert probe_setup == release_setup, 'probe macOS setup differs from release setup'
assert probe_setup.replace('23.1.0', '23.1.5') != release_setup
shell = '\n'.join(line[10:] for line in probe_setup.splitlines()[1:]) + '\n'
assert subprocess.run(['bash', '-n'], input=shell, text=True).returncode == 0
with tempfile.TemporaryDirectory(prefix='xtensa-probe-report-') as td:
    base = Path(td)
    artifacts = base / 'artifacts'
    for runner, platform in [('ubuntu-24.04', 'x86_64-linux'), ('macos-15', 'arm64-macos'),
                             ('macos-15-intel', 'x86_64-macos')]:
        for mode in ('python', 'native'):
            directory = artifacts / f'xtensa-installed-{runner}-{mode}'
            directory.mkdir(parents=True)
            record = dict(installer=mode, platform=platform, status='passed', parentVersion='v0.2.48',
                          version='23.1.3-1', codegen={'a.o': 'hash'}, unpublishedTestFixture=False,
                          statPreservedDsoTamperRejected=True,
                          nativePackageSha256='pin' if mode == 'native' else None)
            (directory / 'result.json').write_text(json.dumps(record))
    output = base / 'comparison.json'
    cmd = [sys.executable, reporter, artifacts, output]
    assert subprocess.run(cmd, stdout=subprocess.DEVNULL).returncode == 0
    path = artifacts / 'xtensa-installed-ubuntu-24.04-native/result.json'
    record = json.loads(path.read_text())
    record['codegen']['a.o'] = 'wrong'
    path.write_text(json.dumps(record))
    assert subprocess.run(cmd, stdout=subprocess.DEVNULL).returncode != 0
    assert json.loads(output.read_text())['status'] == 'failed'
    path.unlink()
    assert subprocess.run(cmd, stdout=subprocess.DEVNULL).returncode != 0
print('xtensa probe report: matching, mismatched and missing legs checked')
