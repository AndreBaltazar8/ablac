#!/usr/bin/env python3
"""Validate the native installation probe reports for all three hosts."""
import argparse
import json
from pathlib import Path

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('artifacts', type=Path)
p.add_argument('output', type=Path)
a = p.parse_args()
platforms = {'ubuntu-24.04': 'x86_64-linux', 'macos-15': 'arm64-macos',
             'macos-15-intel': 'x86_64-macos'}
expected = {'patches.s': 'b860145a355d1b750c82c45903a8dfa5be685112dd444b9320ef0d109f5ce791',
            'patches.o': '528285e41bb3339affe60bf2cb324602bbed246fc147a5799be27c294150e4d1',
            'optimized.o': '8a12b98e9e44d332e9be540e5941a75b41dd3d9cf12068c20d251c72d4622672'}
results, errors = {}, []
for runner, platform in platforms.items():
    path = a.artifacts / f'xtensa-installed-{runner}-native' / 'result.json'
    try:
        report = json.loads(path.read_text())
        if (report.get('installer') != 'native' or report.get('platform') != platform or
                report.get('status') != 'passed' or not report.get('statPreservedDsoTamperRejected') or
                not report.get('nativePackageSha256') or report.get('codegen') != expected):
            raise ValueError('missing or invalid success fields')
        results[platform] = report
    except (OSError, ValueError, json.JSONDecodeError) as e:
        errors.append(f'{runner}: {e}')
if len(results) == 3:
    for key in ('parentVersion', 'version', 'unpublishedTestFixture'):
        if len({json.dumps(report.get(key), sort_keys=True) for report in results.values()}) != 1:
            errors.append(f'{key} differs across hosts')
out = {'status': 'failed' if errors else 'passed', 'errors': errors, 'platforms': results}
a.output.parent.mkdir(parents=True, exist_ok=True)
a.output.write_text(json.dumps(out, indent=2) + '\n')
print(json.dumps(out, indent=2))
if errors:
    raise SystemExit(1)
