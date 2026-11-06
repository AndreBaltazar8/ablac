#!/usr/bin/env python3
"""Actual compiler routing with a stock parent and an explicitly installed cohort."""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

sys.dont_write_bytecode = True
import xtensa_companions as companions

project = Path(__file__).absolute().parent.parent
prefix, out = [Path(arg).absolute() for arg in sys.argv[1:]]
compiler = prefix / 'bin/ablac'
raw_compiler = prefix / 'libexec/ablac.bin'


def run(*args, env=None, expect=None):
    print('+', *map(str, args), flush=True)
    result = subprocess.run(list(map(str, args)), env=env, capture_output=True, text=True, timeout=300)
    if expect:
        assert result.returncode and expect in result.stderr, result
    else:
        assert result.returncode == 0, (result.args, result.stdout, result.stderr)
    return result


def snapshot(root):
    return {str(p.relative_to(root)): ('link', str(p.readlink())) if p.is_symlink() else
            ('file', companions.file_sha256(p), p.stat().st_mode)
            for p in root.rglob('*') if p.is_symlink() or p.is_file()}


env = dict(os.environ, ABLA_CACHE_DIR=str(out / 'cache'))
env.pop('ABLA_XTENSA_LLVM_ROOT', None)
env.pop('ABLA_STDLIB', None)
for name in ('ABLA_ESP_CPU', 'ABLA_XTENSA_DIRECT_CALLS', 'ABLA_XTENSA_NARROW_BRANCHES', 'ABLA_XTENSA_TEXT_LITERALS', 'ABLA_XTENSA_NARROW', 'ABLA_ESP_KEEP_UNWIND'):
    env.pop(name, None)
originals = snapshot(prefix)
run(sys.executable, prefix / 'bin/abla-install-xtensa', '--version', '23.1.3-1', env=env)
run(sys.executable, prefix / 'bin/abla-install-xtensa', '--verify', env=env)
reference = json.loads((project / 'tests/cases/xtensa-routing/nix-objects.json').read_text())
results = []
for entry in reference['objects']:
    source = project / entry['source']
    assert companions.file_sha256(source) == entry['sourceSha256']
    output = out / (entry['name'] + '.o')
    active = dict(env, ABLA_ESP_CPU=entry['cpu'], ABLA_XTENSA_NARROW='1' if entry['narrow'] else '0')
    args = ['build', source, '-o', output, '--target-triple', 'xtensa-esp-unknown-elf',
            '--object-format', 'elf', '--emit', 'object', '--no-cache', '--no-debug']
    if entry['fast']:
        args.append('--fast')
    run(compiler, *args, env=active)
    actual = companions.file_sha256(output)
    assert actual == entry['sha256'], (entry['name'], actual, entry['sha256'])
    results.append({'name': entry['name'], 'sha256': actual})
# A distinct process and output name cannot introduce a temporary FILE symbol.
entry = reference['objects'][0]
repeat = out / 'different-process-output.o'
run(compiler, 'build', project / entry['source'], '-o', repeat,
    '--target-triple', 'xtensa-esp-unknown-elf', '--object-format', 'elf',
    '--emit', 'object', '--no-cache', '--no-debug',
    env=dict(env, ABLA_ESP_CPU=entry['cpu'], ABLA_XTENSA_NARROW='1' if entry['narrow'] else '0'))
assert companions.file_sha256(repeat) == entry['sha256'], 'output path or PID changed object bytes'
# Without the launcher, poison both PATH tools. Automatic selection must still
# derive the same installed cohort from the actual compiler image.
poison = out / 'poison'
poison.mkdir()
for name in ('opt', 'llc'):
    path = poison / name
    path.write_text('#!/bin/sh\necho XTENSA_PATH_POISON >&2\nexit 91\n')
    path.chmod(0o755)
active = dict(env, PATH=str(poison) + os.pathsep + env['PATH'], ABLA_SYSROOT=str(prefix / 'share/abla'))
source = project / 'tests/cases/xtensa-routing/intrinsics.ab'
args = ['build', source, '-o', out / 'poison-proof.o', '--target-triple', 'xtensa-esp-unknown-elf',
        '--object-format', 'elf', '--emit', 'object']
run(raw_compiler, *args, env=active)
keys = set((out / 'cache').glob('native-*.o'))
run(raw_compiler, *args, env=active)
assert set((out / 'cache').glob('native-*.o')) == keys, 'warm installed build missed cache'
# A real library-only identity change must invalidate cache even though its
# content and --version output are unchanged. Restore the owned file metadata.
cohort_root = (prefix / 'lib/abla/xtensa-llvm/current').resolve()
library = next((cohort_root / 'lib').glob('libLLVM*'))
old_info = library.stat()
try:
    os.utime(library, ns=(old_info.st_atime_ns, old_info.st_mtime_ns + 1000000000))
    run(raw_compiler, *args, env=active)
    changed = set((out / 'cache').glob('native-*.o'))
    assert len(changed - keys) == 1, 'real library identity reused cached object'
finally:
    os.utime(library, ns=(old_info.st_atime_ns, old_info.st_mtime_ns))
run(sys.executable, prefix / 'bin/abla-install-xtensa', '--verify', env=env)
# A warm cache cannot conceal a missing selected cohort.
current = prefix / 'lib/abla/xtensa-llvm/current'
held = current.with_name('held-current')
current.rename(held)
try:
    run(raw_compiler, *args, env=active, expect='E_XTENSA_LLVM_MISSING')
finally:
    held.rename(current)
# The synthetic wrapper tests still execute the real private LLVM tools.
active['ABLA_XTENSA_LLVM_ROOT'] = str(current.resolve())
run(sys.executable, project / 'tools/test-xtensa-routing.py', raw_compiler, env=active)
# Parent files remain unchanged, including its ordinary tools and libraries.
after = snapshot(prefix)
assert all(after.get(name) == value for name, value in originals.items()), 'parent toolchain was modified'
report = {'status': 'passed', 'platform': companions.host_platform(), 'parentHasXtensa': 'xtensa ' in (out / 'parent-llc-version.txt').read_text(),
          'parentHasPrivateXtensaOptions': False,
          'unchangedParentEntries': len(originals), 'objects': results,
          'poisonedPathPassed': True, 'missingWarmCohortRejected': True, 'realLibraryIdentityInvalidatedCache': True}
(out / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
