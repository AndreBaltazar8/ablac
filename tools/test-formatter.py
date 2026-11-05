#!/usr/bin/env python3
"""Formatter CLI, syntax-field drift guards and deliberate preservation failures."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys

root = Path(__file__).resolve().parent.parent
compiler = str(Path(sys.argv[1]).absolute())
os.chdir(root)
out = root / 'build/formatter-tests'
if out.exists():
    shutil.rmtree(out)
out.mkdir()
cases = root / 'tests/cases/formatter'


def command(*arguments, source=None, status=0):
    result = subprocess.run([compiler, 'fmt', *map(str, arguments)], input=source,
                            text=True, capture_output=True)
    assert result.returncode == status, (arguments, result.returncode, result.stderr)
    return result


for fixture in sorted(cases.glob('*.input.ab')):
    original = fixture.read_text()
    expected = fixture.with_name(fixture.name.replace('.input.', '.expected.')).read_text()
    formatted = command('-', source=original).stdout
    assert formatted == expected, (fixture.name, formatted, expected)
    assert command('-', source=formatted).stdout == formatted
    check = command('--check', '-', source=original, status=int(original != formatted))
    assert bool(check.stdout) == (original != formatted)
    target = out / fixture.name
    target.write_text(original)
    target.chmod(0o600)
    command('--check', target, status=int(original != formatted))
    assert target.read_text() == original
    command(target)
    assert target.read_text() == expected
    assert target.stat().st_mode & 0o777 == 0o600
    assert command('--check', target).stdout == ''
    print('formatter:', fixture.stem, 'golden, stdin, check, idempotence and mode passed', flush=True)

# Comment and raw-literal bytes must survive even when Python's text-mode I/O
# would otherwise normalize CRLFs and hide a regression.
raw = b'/* exact\r\n  body */\r\nval x = """\r\n  raw\r\n  """\r\n'
r = subprocess.run([compiler, 'fmt', '-'], input=raw, capture_output=True)
assert r.returncode == 0, r.stderr
assert b'/* exact\r\n  body */' in r.stdout
assert b'"""\r\n  raw\r\n  """' in r.stdout

# Build API modules are source, while generated build output stays untouched.
selection = out / 'selection'
module = selection / 'stdlib/abla/build/entry.ab'
artifact = selection / 'build/generated.ab'
module.parent.mkdir(parents=True)
artifact.parent.mkdir(parents=True)
module.write_text('fun main:int=0\n')
artifact.write_text('fun main:int=0\n')
command(selection)
assert module.read_text() == 'fun main: int = 0\n'
assert artifact.read_text() == 'fun main:int=0\n'

# Newline-at-EOF diffs and exact opaque bytes, including CRLF raw/comment text.
for text in ['', '\n\n', 'fun main:int=0', '// comment\r\nfun main:int=0\r\n',
             '/* exact\r\n  body */\r\nfun main:int=0\r\n']:
    formatted = command('-', source=text).stdout
    assert command('-', source=formatted).stdout == formatted

valid = out / '000-valid.ab'
invalid = out / '999-invalid.ab'
valid.write_text('fun main:int=0\n')
invalid.write_text('fun broken( {\n')
command(valid, invalid, status=2)
assert valid.read_text() == 'fun main:int=0\n'
assert invalid.read_text() == 'fun broken( {\n'
command('--width', '0', valid, status=2)
command('--unknown', valid, status=2)
command('-', valid, source='', status=2)
link = out / 'symbolic.ab'
link.symlink_to(valid.name)
command(link, status=2)
assert link.is_symlink() and valid.read_text() == 'fun main:int=0\n'

# This guard fails when a new parser field has no explicit comparison policy.
parser = (root / 'src/parser.ab').read_text()
formatter = (root / 'src/formatter.ab').read_text()
for cls, function, positions in [
    ('BootstrapExpression', 'bootstrapFormatExpressionEqual', {'begin', 'end'}),
    ('BootstrapDeclaration', 'bootstrapFormatDeclarationEqual',
     {'begin', 'end', 'generatedOriginBegin', 'generatedOriginEnd', 'annotationBegins', 'annotationEnds'}),
    ('BootstrapParseResult', 'bootstrapFormatAstEqual', set()),
]:
    body = re.search(r'class ' + cls + r'\((.*?)\n\)', parser, re.S).group(1)
    fields = re.findall(r'^\s*(?:val|var)\s+(\w+):', body, re.M)
    body = formatter.split('fun ' + function + '(', 1)[1].split('\nfun ', 1)[0]
    for field in fields:
        assert field in positions or ('left.' + field in body and 'right.' + field in body), (cls, field)

program = out / 'guard'
subprocess.run([compiler, 'build', str(cases / 'guard.ab'), '-o', str(program),
                '--fast', '--no-cache'], check=True)
environment = dict(os.environ, ABLA_FORMATTER_EXPECTED_FILES=str(
    len(list((root / 'src').rglob('*.ab'))) + len(list((root / 'stdlib').rglob('*.ab')))))
result = subprocess.run([str(program)], env=environment)
assert result.returncode == 42, ('formatter preservation negatives', result.returncode)
print('formatter: token/AST/comment/idempotence negative controls and invalid-input no-write passed', flush=True)
