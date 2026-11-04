"""Offline value/diagnostic corpus. The upstream event stream is the oracle,
not a parser installed on the test machine. See UPSTREAM.md for provenance."""
import json
from pathlib import Path
import subprocess
import sys

probe, output = sys.argv[1:]
root = Path(__file__).parent
source = Path(output) / 'case.yaml'
cases = json.loads((root / 'fixtures.json').read_text())
for case in cases:
    source.write_bytes(case['source'].encode('utf-8'))
    result = subprocess.run([probe, str(source)], text=True, capture_output=True, timeout=5)
    try:
        actual = json.loads(result.stdout)
    except ValueError:
        raise AssertionError((case['name'], result.returncode, result.stdout, result.stderr))
    if case.get('error'):
        assert result.returncode == 1 and actual[0] == 'error', (case['name'], actual)
    else:
        assert result.returncode == 0 and actual == case['expected'], (case['name'], actual, case['expected'])
        for style in ['block', 'flow']:
            emitted = subprocess.run([probe, str(source), style], text=True, capture_output=True, timeout=5)
            assert emitted.returncode == 0, (case['name'], style, emitted.returncode, emitted.stdout, emitted.stderr)
            assert json.loads(emitted.stdout) == case['expected'], (case['name'], style, emitted.stdout)
print(f'YAML: {len(cases)} offline parser vectors passed')
