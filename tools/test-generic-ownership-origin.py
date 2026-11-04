from pathlib import Path
import os
import re
import shutil
import subprocess
import sys

compiler, root = Path(sys.argv[1]), Path(sys.argv[2])
cases = root / 'tests/cases/generic-ownership-origin'
out = root / 'build/generic-ownership-origin'
sysroot = out / 'sysroot'
if sysroot.exists():
    shutil.rmtree(sysroot)
shutil.copytree(root / 'stdlib', sysroot / 'stdlib', symlinks=True)
helper = sysroot / 'stdlib/abla/array/ownership-probe/entry.ab'
helper.parent.mkdir(parents=True)
shutil.copyfile(cases / 'helper.ab', helper)
type_helper = sysroot / 'stdlib/abla/array/ownership-type-error/entry.ab'
type_helper.parent.mkdir(parents=True)
shutil.copyfile(cases / 'helper-type-error.ab', type_helper)
env = dict(os.environ, ABLA_SYSROOT=str(sysroot),
           ABLA_CACHE_DIR=str(out / 'cache'))


def build(name, suffix=''):
    source = cases / (name + '.ab')
    result = subprocess.run([str(compiler), 'build', str(source), '-o',
                             str(out / 'program'), '--fast', '--no-cache'],
                            cwd=root, env=env, capture_output=True, text=True)
    (out / (name + suffix + '.log')).write_text(result.stdout + result.stderr)
    return source, result


for name, call, others in [('single', 'xs.invalidPop()', 0),
                            ('shared', 'xs.invalidPop()', 2),
                            ('shared-two', 'xs.invalidPop()', 1),
                            ('nested', 'xs.nestedPop()', 0),
                            ('mixed', 'xs.nestedPop()', 2),
                            ('cyclic', 'xs.cyclicPop(false)', 0)]:
    source, result = build(name)
    assert result.returncode != 0, (name, 'invalid ownership accepted')
    begin = source.read_bytes().index(call.encode())
    expected = f'source[semantic]:{source}:{begin}:{begin + len(call)}'
    blocks = re.split(r'(?=^error\[)', result.stderr, flags=re.M)
    ownership = [block for block in blocks if block.startswith('error[')
                 and ': ownership.' in block.splitlines()[0]]
    assert ownership, (name, result.stderr)
    for block in ownership:
        assert expected in block, (name, expected, block)
        assert f'source[generic-helper]:{helper}:' in block, (name, block)
        assert block.index(expected) < block.index('source[generic-helper]'), block
        assert 'context[generic-instance]:' in block, block
        assert 'note: ownership error in this generic helper' in block, block
        if others:
            assert f'and {others} other call site' in block, block
        if not others:
            assert 'other call site' not in block, block
    _, repeated = build(name, '-repeat')
    assert repeated.stderr == result.stderr, (name, 'unstable source order/count')

source, plain = build('plain')
assert plain.returncode != 0 and 'ownership.place-move-required' in plain.stderr
assert f'source[semantic]:{source}:' in plain.stderr
assert 'generic-helper' not in plain.stderr and 'other call site' not in plain.stderr
_, wrong_type = build('type-error')
assert wrong_type.returncode != 0, 'bad generic definition accepted'
assert f'source[semantic]:{type_helper}:' in wrong_type.stderr, wrong_type.stderr
assert 'generic-helper' not in wrong_type.stderr, wrong_type.stderr
_, valid = build('valid')
assert valid.returncode == 0, valid.stderr
assert subprocess.run([str(out / 'program')], cwd=out, env=env).returncode == 42
print('generic ownership: caller first, helper note, shared source order, nested/cyclic origins, other errors unchanged')
