import json
from pathlib import Path
import subprocess
import sys

probe, output = sys.argv[1:]
root = Path(__file__).parent
spec = Path(output) / 'edit.json'
errors = []
cases = json.loads((root / 'edit-fixtures.json').read_text())
# Every supported upstream input must retain its complete concrete source.
for case in json.loads((root / 'fixtures.json').read_text()):
    if 'expected' in case:
        cases.append(dict(name='no-op-'+case['name'], source=case['source'], ops=[], text=case['source']))
        cases.append(dict(name='no-op-set-'+case['name'], source=case['source'], ops=[dict(op='set',path=[],value=case['source'])], text=case['source']))
for case in cases:
    spec.write_text(json.dumps(case))
    process = subprocess.run([probe, str(spec)], capture_output=True, text=True, timeout=5)
    try:
        assert process.returncode == 0, (process.returncode, process.stderr)
        result = json.loads(process.stdout)
        if 'error' in case:
            assert not result['succeeded'] and result['error'] == case['error'], result
            assert result['text'] == case['source'], ('transaction did not roll back', result)
        else:
            assert result['succeeded'], result
            if 'text' in case:
                assert result['text'] == case['text'], (result['text'], case['text'])
            if 'value' in case:
                assert result['value'][0] == 'map', result
                fields = {entry[0][1]:entry[1] for entry in result['value'][1]}
                assert fields['a'] == ['str', case['value']], result
                assert result['text'].startswith(case['prefix']+case['style']), result
                assert result['text'].endswith(case['suffix']), result
                assert '# header' in result['text'], result
    except Exception as error:
        errors.append((case['name'],str(error)))
for name, error in errors:
    print(name, error)
print(f'YAML editing: {len(cases)-len(errors)}/{len(cases)} vectors passed')
raise SystemExit(bool(errors))
