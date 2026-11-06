#!/usr/bin/env python3
"""Targeted routing/cache controls; requires the selected real Xtensa cohort."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile
import time

compiler = os.path.abspath(sys.argv[1])  # Preserve build/ablac's launcher name.
project = Path(__file__).absolute().parent.parent
selected = Path(os.environ['ABLA_XTENSA_LLVM_ROOT'])
manifest = json.loads((selected / 'manifest.json').read_text())
real_opt = (selected / 'bin/opt').resolve()
real_llc = (selected / 'bin/llc').resolve()
version = manifest['llvmVersion']
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()

with tempfile.TemporaryDirectory(prefix='abla Xtensa routing ') as temporary:
    root = Path(temporary).resolve()
    source = root / 'probe.ab'
    source.write_text('@export("probe")\nfun probe(value: int): int = (value & 255) + 7\n')
    trace = root / 'trace.jsonl'
    env = dict(os.environ, ABLA_SYSROOT=str(project), ABLA_CACHE_DIR=str(root / 'cache'),
               ABLA_XTENSA_ROUTING_TRACE=str(trace))
    env.pop('ABLA_STDLIB', None)
    for name in ('ABLA_ESP_CPU', 'ABLA_XTENSA_DIRECT_CALLS', 'ABLA_XTENSA_NARROW_BRANCHES',
                 'ABLA_XTENSA_TEXT_LITERALS', 'ABLA_XTENSA_NARROW', 'ABLA_ESP_KEEP_UNWIND', 'ABLA_XTENSA_FEATURES'):
        env.pop(name, None)

    def cohort(name):
        tree = root / name
        (tree / 'bin').mkdir(parents=True)
        (tree / 'lib').mkdir()
        # Synthetic manifest/wrappers exercise the resolver; the wrappers run
        # the actual Nix/private LLVM tools, not a simulated optimizer.
        for tool, real in [('opt', real_opt), ('llc', real_llc)]:
            script = tree / 'bin' / tool
            script.write_text('#!' + sys.executable + '\n' +
                'import json,os,sys\n' +
                'from pathlib import Path\n' +
                'with open(os.environ["ABLA_XTENSA_ROUTING_TRACE"],"a") as f:\n' +
                ' f.write(json.dumps({"tool":' + repr(tool) + ',"cohort":' + repr(name) + ',"args":sys.argv[1:]})+"\\n")\n' +
                'if sys.argv[1:]==["--version"] and os.environ.get("ABLA_TEST_SWITCH_FROM")=='+repr(str(tree))+':\n' +
                ' link=Path(os.environ["ABLA_TEST_SWITCH_LINK"]); nxt=link.with_name("next-link")\n' +
                ' if not nxt.exists():\n' +
                '  nxt.symlink_to(os.environ["ABLA_TEST_SWITCH_TO"]); os.replace(nxt,link)\n' +
                'os.execv(' + repr(str(real)) + ',[' + repr(str(real)) + ']+sys.argv[1:])\n')
            script.chmod(0o755)
        (tree / 'lib/libLLVM-test-identity').write_text('Synthetic identity file; real tools use their own immutable libraries.\n')
        data = {'schema': 1, 'version': 'abla-xtensa-llvm-' + version + '-1',
                'platform': manifest['platform'], 'llvmVersion': version,
                'sourceCommit': 'a'*40, 'sourceArchiveSha256': 'b'*64,
                'files': {str(p.relative_to(tree)): sha(p) for p in tree.rglob('*') if p.is_file()}}
        (tree / 'manifest.json').write_text(json.dumps(data))
        return tree

    first, second = cohort('first'), cohort('second')
    env['ABLA_XTENSA_LLVM_ROOT'] = str(first)
    poison = root / 'poison'
    poison.mkdir()
    for name in ('opt', 'llc'):
        p = poison / name
        p.write_text('#!/bin/sh\necho PATH_POISON_WAS_EXECUTED >&2\nexit 91\n')
        p.chmod(0o755)
    env['PATH'] = str(poison) + os.pathsep + env['PATH']

    def rows():
        return [json.loads(line) for line in trace.read_text().splitlines()] if trace.exists() else []

    def build(label, extra=(), changes=None, expected=None):
        active = dict(env)
        active.update(changes or {})
        command = [compiler, 'build', str(source), '-o', str(root / (label + '.o')),
                   '--target-triple', 'xtensa-esp-unknown-elf', '--object-format', 'elf', '--emit', 'object', *extra]
        result = subprocess.run(command, env=active, capture_output=True, text=True, timeout=180)
        if expected:
            assert result.returncode and expected in result.stderr, (label, result)
        else:
            assert result.returncode == 0, (label, result.stdout, result.stderr)
        assert 'PATH_POISON_WAS_EXECUTED' not in result.stderr, result.stderr
        return result

    def emissions():
        return [row for row in rows() if row['tool'] == 'llc' and '-filetype=asm' in row['args']]

    build('cold')
    assert len(emissions()) == 1
    call = emissions()[-1]['args']
    assert '-mcpu=esp32' in call and '-relocation-model=static' in call
    assert '-xtensa-direct-calls' in call and '-xtensa-narrow-branches' in call
    assert '-xtensa-text-section-literals' not in call
    build_manifest = json.loads((root / 'cold.o.xtensa-tools.json').read_text())
    assert build_manifest['assemblyNarrowing'] is True
    assert 'a2fd95380faf9c54' in build_manifest['stage']
    build('warm')
    assert len(emissions()) == 1, 'unchanged build did not hit cache'
    build('no-narrow', changes={'ABLA_XTENSA_NARROW': '0'})
    build_manifest = json.loads((root / 'no-narrow.o.xtensa-tools.json').read_text())
    assert build_manifest['assemblyNarrowing'] is False
    assert len(emissions()) == 2, 'narrow opt-out reused the wrong cache entry'
    build('fast', ['--fast'])
    assert '-O0' in emissions()[-1]['args'] and '-relocation-model=static' in emissions()[-1]['args']
    before = len(emissions())
    for chip, cpu, feature in [('esp32s2', 'esp32s2', None), ('esp32s3', 'esp32', '-mattr=-dfpaccel')]:
        build(chip, changes={'ABLA_ESP_CPU': chip})
        call = emissions()[-1]['args']
        assert '-mcpu=' + cpu in call
        if feature:
            assert feature in call
        opt_call = [r for r in rows() if r['tool'] == 'opt' and '--version' not in r['args']][-1]['args']
        assert '-mcpu=' + cpu in opt_call
        if feature:
            assert feature in opt_call
    assert len(emissions()) == before + 2, 'CPU/features did not invalidate cache'
    build('options', changes={'ABLA_XTENSA_DIRECT_CALLS': '0', 'ABLA_XTENSA_NARROW_BRANCHES': '0', 'ABLA_XTENSA_TEXT_LITERALS': '1'})
    call = emissions()[-1]['args']
    assert '-xtensa-direct-calls' not in call and '-xtensa-narrow-branches' not in call
    assert '-xtensa-text-section-literals' in call
    before = len(emissions())
    build('feature-override', changes={'ABLA_XTENSA_FEATURES': '-mul32high,+density'})
    assert '-mattr=-mul32high,+density' in emissions()[-1]['args']
    opt_call = [r for r in rows() if r['tool'] == 'opt' and '--version' not in r['args']][-1]['args']
    assert '-mattr=-mul32high,+density' in opt_call
    assert len(emissions()) == before + 1, 'feature override reused cached object'
    build('feature-warm', changes={'ABLA_XTENSA_FEATURES': '-mul32high,+density'})
    assert len(emissions()) == before + 1, 'unchanged feature override missed cache'
    for invalid in ['mul32high', '-', ',+density', '+density,', '-mul32high,,+density', '-mul32high, +density', '+density\n-O0', '+bad/name']:
        build('bad-features', changes={'ABLA_XTENSA_FEATURES': invalid}, expected='E_XTENSA_FEATURES')
    build('badcpu', changes={'ABLA_ESP_CPU': 'esp32c3'}, expected='E_XTENSA_CPU')
    build('missing', changes={'ABLA_XTENSA_LLVM_ROOT': str(root / 'missing')}, expected='E_XTENSA_LLVM_MISSING')
    saved_manifest = (first / 'manifest.json').read_text()
    (first / 'manifest.json').write_text('{ broken json')
    build('bad-json', expected='E_XTENSA_LLVM_MANIFEST')
    data = json.loads(saved_manifest)
    data['files']['../escape'] = '0' * 64
    (first / 'manifest.json').write_text(json.dumps(data))
    build('traversal', expected='E_XTENSA_LLVM_MANIFEST')
    (first / 'manifest.json').write_text(saved_manifest)
    llc_saved = first / 'bin/saved-llc'
    (first / 'bin/llc').rename(llc_saved)
    build('warm-missing-helper', expected='E_XTENSA_LLVM_FILE')
    llc_saved.rename(first / 'bin/llc')
    before = len(emissions())
    lib = first / 'lib/libLLVM-test-identity'
    lib.write_text(lib.read_text() + 'ordinary replacement\n')
    build('library-replaced')
    assert len(emissions()) == before + 1, 'library replacement reused cached object'
    before = len(emissions())
    script = first / 'bin/llc'
    script.write_text(script.read_text() + '# changed helper revision\n')
    build('helper-replaced')
    assert len(emissions()) == before + 1, 'helper replacement reused cached object'
    lib.rename(lib.with_name('held'))
    build('warm-missing-library', expected='E_XTENSA_LLVM_FILE')
    lib.with_name('held').rename(lib)
    data = json.loads((first / 'manifest.json').read_text())
    original = json.dumps(data)
    data['platform'] = 'wrong-host'
    (first / 'manifest.json').write_text(json.dumps(data))
    build('badhost', expected='E_XTENSA_LLVM_HOST')
    data['platform'] = manifest['platform']
    data['llvmVersion'] = '999.0.0'
    (first / 'manifest.json').write_text(json.dumps(data))
    build('badversion', expected='E_XTENSA_LLVM_VERSION')
    (first / 'manifest.json').write_text(original)
    before = len(emissions())
    data['llvmVersion'] = version
    data['version'] = data['version'].rsplit('-', 1)[0] + '-2'
    (first / 'manifest.json').write_text(json.dumps(data))
    build('manifest-replaced')
    assert len(emissions()) == before + 1, 'manifest revision reused cached object'
    current = root / 'current'
    current.symlink_to(first)
    before = len(rows())
    build('switch-during-resolution', ['--no-cache'], changes={
        'ABLA_XTENSA_LLVM_ROOT': str(current), 'ABLA_TEST_SWITCH_FROM': str(first),
        'ABLA_TEST_SWITCH_TO': str(second), 'ABLA_TEST_SWITCH_LINK': str(current)})
    assert current.resolve() == second
    assert {row['cohort'] for row in rows()[before:]} == {'first'}, 'selection changed during build'
    before = len(rows())
    build('next-selection', changes={'ABLA_XTENSA_LLVM_ROOT': str(current)})
    assert {row['cohort'] for row in rows()[before:]} == {'second'}
    # The SDK's GNU layout markers survive as comments in LLVM's assembler;
    # refusing live markers prevents a silently different vector layout.
    marker_source = ('trusted noescape extern:"inline-assembly" fun marked(template: string, constraints: string): void\n'
                     '@export("marker_probe")\ntrusted fun probe(): void = marked("# ABLA_XTENSA_LITERAL_ISLAND", "~{memory}")\n')
    source.write_text(marker_source)
    build('kept-gnu-marker', ['--no-cache'], expected='E_XTENSA_EXTERNAL_ASSEMBLER')
    source.write_text('trusted noescape extern:"inline-assembly" fun marked(template: string, constraints: string): void\n'
                      'fun never(): bool = false\n'
                      '@export("plain_probe")\ntrusted fun probe(value: int): int {\n'
                      ' if (never()) marked("# ABLA_XTENSA_LITERAL_ISLAND", "~{memory}")\n'
                      ' value + 1\n}\n')
    build('dead-gnu-marker', ['--no-cache'])
    assert any(row['tool'] == 'opt' and any(arg.endswith('.checked.ll') for arg in row['args']) for row in rows()), 'dead-marker control did not inspect optimized IR'
    # The ordinary host path ignores even a deliberately missing Xtensa root.
    host = subprocess.run([compiler, 'build', str(source), '-o', str(root / 'host.o'),
                           '--emit', 'object', '--fast', '--no-cache'],
                          env=dict(env, ABLA_XTENSA_LLVM_ROOT=str(root / 'missing')),
                          capture_output=True, text=True, timeout=180)
    assert host.returncode == 0, host.stderr
    print('Xtensa routing: absolute helpers, poisoned PATH, CPU/options, cache identity, warm refusals and immutable selection passed')
