#!/usr/bin/env python3
"""Compare the manually dispatched Python and native installation legs."""
import argparse
import json
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('artifacts', type=Path)
p.add_argument('output', type=Path)
a = p.parse_args()
platforms = {'ubuntu-24.04': 'x86_64-linux', 'macos-15': 'arm64-macos',
             'macos-15-intel': 'x86_64-macos'}
results, errors = {}, []
for runner, platform in platforms.items():
    pair = {}
    for mode in ('python', 'native'):
        path = a.artifacts / f'xtensa-installed-{runner}-{mode}' / 'result.json'
        try:
            report = json.loads(path.read_text())
            if (report.get('installer') != mode or report.get('platform') != platform or
                    report.get('status') != 'passed' or not report.get('statPreservedDsoTamperRejected')):
                raise ValueError('missing or invalid success fields')
            if mode == 'native' and not report.get('nativePackageSha256'):
                raise ValueError('missing native package identity')
            pair[mode] = report
        except (OSError, ValueError, json.JSONDecodeError) as e:
            errors.append(f'{runner}/{mode}: {e}')
    if len(pair) == 2:
        for key in ('parentVersion', 'version', 'codegen', 'unpublishedTestFixture'):
            if pair['python'].get(key) != pair['native'].get(key):
                errors.append(f'{runner}: {key} differs')
    results[platform] = pair
out = {'status': 'failed' if errors else 'passed', 'errors': errors, 'platforms': results}
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_text(json.dumps(out, indent=2) + '\n')
print(json.dumps(out, indent=2))
if errors:
    raise SystemExit(1)
