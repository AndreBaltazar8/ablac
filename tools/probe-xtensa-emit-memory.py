#!/usr/bin/env python3
"""Manual CI diagnosis, not a timing/peak pass gate; compare two frozen revisions."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import statistics
import subprocess
import sys
import tarfile

assert os.environ.get('GITHUB_ACTIONS') == 'true', 'memory probe is manual CI only'
root = Path(__file__).absolute().parent.parent
out = root / 'build/xtensa-emit-memory'
out.mkdir(parents=True, exist_ok=True)
refs = dict(old='dffc60aab1dfd844707f328d5bad0667e68fc1aa',
            new='13ddb261f96d7cabad176abb737a9ddc319276ae')
cpus = set(sorted(os.sched_getaffinity(0))[:4])
os.sched_setaffinity(0, cpus)
subprocess.run(['git', 'fetch', '--no-tags', '--depth=1', 'origin', *refs.values()], cwd=root, check=True)
snapshots = {}
for name, ref in refs.items():
    destination = out / ('source-' + name)
    destination.mkdir(exist_ok=True)
    archive = out / (name + '.tar')
    with archive.open('wb') as stream:
        subprocess.run(['git', 'archive', ref, 'src'], cwd=root, stdout=stream, check=True)
    with tarfile.open(archive) as stream:
        stream.extractall(destination, filter='data')
    snapshots[name] = destination / 'src'
bootstrap = out / 'bootstrap.bin'
subprocess.run([str(root / 'tools/bootstrap-compiler.sh'), str(bootstrap)], check=True)
env = dict(os.environ, ABLA_SYSROOT=str(root), ABLA_MAX_MEMORY_MB='4096', ABLA_MAX_SECONDS='1800')
rows = []
compilers = {}
source = root / 'src'
saved = out / 'original-src'
assert source.is_dir() and not source.is_symlink() and not saved.exists()
source.rename(saved)


def activate(name):
    if source.exists():
        shutil.rmtree(source)  # Only a copy made by this invocation, never saved.
    shutil.copytree(snapshots[name], source)


def measure(source_name, compiler_name, round_, pressure):
    stem = f'{source_name}-{compiler_name}-{round_}-' + ('loaded' if pressure else 'idle')
    timing, errors = out / (stem + '.time'), out / (stem + '.err')
    active = dict(env, ABLA_COMPILER_PAYLOAD=str(compilers[compiler_name]),
                  ABLA_NATIVE_JOBS='1', ABLA_CODEGEN_JOBS='1', ABLA_COMPILER_MEMORY_TRACE='1',
                  ABLA_CACHE_DIR=str(out / (stem + '-cache')))
    with (out / 'current.ll').open('wb') as stdout, errors.open('wb') as stderr:
        subprocess.run(['/usr/bin/env', 'time', '-f', '%M %e', '-o', str(timing),
                        str(root / 'tools/run-limited-compiler.sh'), '--emit-llvm', str(source / 'orc_main.ab')],
                       cwd=root, env=active, stdout=stdout, stderr=stderr, check=True, timeout=1810)
    peak, wall = timing.read_text().split()
    live = {}
    for line in errors.read_text().splitlines():
        if line.startswith(('abla-ir-memory ', 'abla-llvm-memory ')):
            label, value = line.rsplit(' ', 1)
            live[label] = int(value)
    row = dict(source=source_name, compiler=compiler_name, round=round_, pressure=pressure,
               peakKiB=int(peak), wallSeconds=float(wall), liveByPhase=live,
               irBytes=(out / 'current.ll').stat().st_size,
               irSha256=hashlib.sha256((out / 'current.ll').read_bytes()).hexdigest())
    rows.append(row)
    (out / 'samples.json').write_text(json.dumps(rows, indent=2) + '\n')
    print({key: value for key, value in row.items() if key != 'liveByPhase'}, flush=True)


try:
    for name in refs:
        activate(name)
        compiler = out / ('compiler-' + name + '.bin')
        active = dict(env, ABLA_COMPILER_PAYLOAD=str(bootstrap), ABLA_NATIVE_JOBS='4', ABLA_CODEGEN_JOBS='4')
        subprocess.run([str(root / 'tools/run-limited-compiler.sh'), 'build', str(source / 'orc_main.ab'),
                        '--no-cache', '-o', str(compiler)], cwd=root, env=active, check=True, timeout=1810)
        compilers[name] = compiler
    for source_name in refs:
        activate(source_name)
        for round_ in range(3):
            for compiler_name in (['old', 'new'] if round_ % 2 == 0 else ['new', 'old']):
                measure(source_name, compiler_name, round_, False)
    # Reproduce CPU contention within the same four-core affinity, without
    # introducing other compiler heaps. Keep these owned children joined.
    activate('new')
    hogs = [subprocess.Popen([sys.executable, '-c', 'while True: pass'], stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL) for _ in range(min(3, len(cpus) - 1))]
    try:
        for round_ in range(3):
            for compiler_name in (['old', 'new'] if round_ % 2 == 0 else ['new', 'old']):
                measure('new', compiler_name, round_, True)
    finally:
        for hog in hogs:
            hog.terminate()
        for hog in hogs:
            hog.wait(timeout=10)
finally:
    if source.exists():
        shutil.rmtree(source)
    saved.rename(source)

summary = []
for source_name in refs:
    for compiler_name in refs:
        for pressure in [False, True]:
            peaks = [row['peakKiB'] for row in rows if row['source'] == source_name
                     and row['compiler'] == compiler_name and row['pressure'] == pressure]
            if peaks:
                summary.append(dict(source=source_name, compiler=compiler_name, pressure=pressure,
                                    medianKiB=statistics.median(peaks), minKiB=min(peaks), maxKiB=max(peaks)))
result = dict(status='measured', refs=refs, cpus=sorted(cpus), summary=summary)
(out / 'result.json').write_text(json.dumps(result, indent=2) + '\n')
print(json.dumps(result, indent=2))
