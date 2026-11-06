#!/usr/bin/env python3
"""Explicit CI-only frozen firmware gate through a real installed companion."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
sys.dont_write_bytecode = True
from xtensa_elf_fingerprint import fingerprint

assert os.environ.get('GITHUB_ACTIONS') == 'true', 'installed embedded probe is CI-only'
assert sys.platform.startswith('linux'), 'this capacity probe requires Linux'
root = Path(__file__).absolute().parent.parent
prefix, embedded, out = [Path(arg).absolute() for arg in sys.argv[1:]]
reference = json.loads((root / 'tests/cases/xtensa-routing/firmware-reference.json').read_text())
actual = subprocess.check_output(['git', '-c', 'safe.directory=' + str(embedded), '-C', str(embedded), 'rev-parse', 'HEAD'], text=True).strip()
assert actual == reference['revision'], (actual, reference['revision'])
entry = embedded / reference['entry']
assert hashlib.sha256(entry.read_bytes()).hexdigest() == reference['entrySha256']
assert shutil.which('prlimit'), '4 GiB address-space enforcement requires prlimit'
assert Path('/usr/bin/time').is_file(), 'capacity probe requires GNU time'
os.sched_setaffinity(0, set(sorted(os.sched_getaffinity(0))[:4]))

# Run the actual firmware compiler path without the SDK wrapper's independent
# llc/llvm-mc self-test: that wrapper requires the full patched developer LLVM,
# while the companion deliberately supplies only opt, llc and libLLVM.
compiler = root / 'tools/run-limited-compiler.sh'
env = dict(os.environ, ABLA_COMPILER_PAYLOAD=str(prefix / 'libexec/ablac.bin'), ABLA_SYSROOT=str(prefix / 'share/abla'),
           ABLA_MAX_MEMORY_MB='4096', ABLA_NATIVE_JOBS='4', JOBS='4',
           ABLA_CACHE_DIR=str(out / 'embedded-cache'), PATH=str(prefix / 'bin') + os.pathsep + os.environ['PATH'])
for name in ['ABLA_STDLIB', 'ABLA_XTENSA_LLVM_ROOT', 'ABLA_ESP_CPU', 'ABLA_XTENSA_NARROW',
             'ABLA_XTENSA_DIRECT_CALLS', 'ABLA_XTENSA_NARROW_BRANCHES',
             'ABLA_XTENSA_TEXT_LITERALS', 'ABLA_ESP_KEEP_UNWIND', 'ABLA_XTENSA_FEATURES']:
    env.pop(name, None)
timing = out / 'embedded-check-time.json'
narrow = out / 'embedded-firmware-narrow-build.o'
with (out / 'embedded-check-source.log').open('wb') as log:
    subprocess.run(['/usr/bin/time', '-f', '{"peakKiB":%M,"wallSeconds":%e}', '-o', str(timing),
                    str(compiler), 'build', str(entry), '--target-triple', 'xtensa-esp-unknown-elf',
                    '--object-format', 'elf', '--emit', 'object', '--no-cache', '-o', str(narrow)], cwd=embedded, env=env,
                   stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1800)
print((out / 'embedded-check-source.log').read_text(), flush=True)
measurements = json.loads(timing.read_text())
assert measurements['peakKiB'] < 4096 * 1024, measurements


def verify(path, kind):
    expected = reference['objects'][kind]
    raw = path.read_bytes()
    actual = hashlib.sha256(raw).hexdigest()
    assert len(raw) == expected['bytes'], (kind, len(raw), expected['bytes'])
    if kind == 'narrow':
        assert actual == expected['sha256'], (kind, actual, expected['sha256'])
    else:
        # Only explicit RELA-covered L32R immediates may differ from direct
        # object emission; source opcode/register bytes stay exact.
        assert fingerprint(raw, controls=True) == expected['relocationMasked'], kind
    destination = out / ('embedded-firmware-' + kind + '.o')
    shutil.copyfile(path, destination)
    manifest = json.loads(Path(str(path) + '.xtensa-tools.json').read_text())
    assert manifest['assemblyNarrowing'] == (kind == 'narrow')
    cohort = (prefix / 'lib/abla/xtensa-llvm/current').resolve()
    assert str(cohort) in manifest['identity']
    assert 'a254932917786ca006920fcb8ec02f3c5556dd06' in manifest['identity']
    return dict(kind=kind, bytes=len(raw), sha256=actual, stage=manifest['stage'],
                comparison='whole-object' if kind == 'narrow' else 'L32R fields masked plus normalized RELA',
                linkedCheck='unavailable: companion intentionally has no GNU firmware linker')


objects = [verify(narrow, 'narrow')]
wide = out / 'embedded-firmware-wide-build.o'
subprocess.run([str(compiler), 'build', str(entry), '--target-triple', 'xtensa-esp-unknown-elf',
                '--object-format', 'elf', '--emit', 'object', '--no-cache', '-o', str(wide)],
               cwd=embedded, env=dict(env, ABLA_XTENSA_NARROW='0'), check=True, timeout=600)
objects.append(verify(wide, 'wide'))
subprocess.run([sys.executable, str(prefix / 'bin/abla-install-xtensa'), '--verify'], env=env, check=True, timeout=120)
result = json.loads((out / 'result.json').read_text())
result['embedded'] = dict(status='passed', revision=actual, limitMiB=4096,
                          peakMetric='GNU time %M: largest single process, not summed children',
                          **measurements, objects=objects)
(out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result['embedded'], indent=2))
