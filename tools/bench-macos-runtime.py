#!/usr/bin/env python3
"""Measure released macOS programs; no production compiler/runtime changes.

Each compiler uses its own release-tag stdlib. Both compile the same frozen
benchmark sources. Warm up once, then alternate five process-level runs per arm.
Darwin time(1) reports peak RSS in bytes. No CPU-affinity or hardware-counter
claim: hosted GitHub runners are noisy and macOS chooses the core.
"""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import resource
import statistics
import subprocess
import time

VERSIONS = ('v0.2.45', 'v0.2.47')
PROGRAMS = {name: {'source': f'tests/benchmarks/perf/{name}.ab', 'args': []}
            for name in 'fib sieve nbody trees strings maps dispatch matrix'.split()}
PROGRAMS.update({
    'websocket-codec': {'source': 'tests/benchmarks/websocket-codec.ab', 'args': []},
    'json-readers': {'source': 'tests/benchmarks/json-readers.ab', 'args': ['3000', '100']},
    'json-megabyte': {'source': 'tests/benchmarks/json-megabyte.ab', 'args': ['30000']},
    'event-http-server': {'source': 'examples/event-http-server.ab', 'args': None},
    'https-client': {'source': 'examples/https-client.ab', 'args': None},
})


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def stack_limit():
    soft, hard = resource.getrlimit(resource.RLIMIT_STACK)
    wanted = 131072 * 1024
    resource.setrlimit(resource.RLIMIT_STACK,
                       (wanted if hard == resource.RLIM_INFINITY else min(wanted, hard), hard))


def time_metrics(stderr):
    result = {}
    for label, key in [('real', 'timeRealSeconds'), ('user', 'userSeconds'), ('sys', 'systemSeconds')]:
        matches = re.findall(r'^' + label + r'\s+(\d+(?:\.\d+)?)\s*$', stderr, re.M)
        if not matches:
            raise ValueError(f'missing Darwin time metric {label}')
        result[key] = float(matches[-1])
    matches = re.findall(r'^\s*(\d+)\s+maximum resident set size\s*$', stderr, re.M)
    if not matches:
        raise ValueError('missing Darwin time peak RSS')
    result['rssBytes'] = int(matches[-1])
    return result


def normalized_output(name, output):
    if 'MISMATCH' in output:
        raise ValueError(f'{name} reports MISMATCH')
    if name == 'json-readers':
        output = re.sub(r'\d+(?:\.\d+)? ns/field', '<time> ns/field', output)
    elif name == 'json-megabyte':
        output = re.sub(r': \d+ ms \(\d+ MB/s\)', ': <time> ms (<rate> MB/s)', output)
    elif name == 'websocket-codec':
        output = re.sub(r' in \d+ms', ' in <time>ms', output)
    return output


def summary(values):
    return dict(median=statistics.median(values), minimum=min(values), maximum=max(values),
                spreadPercent=(max(values) - min(values)) / statistics.median(values) * 100
                if statistics.median(values) else None)


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + '\n')


def run(args):
    if platform.system() != 'Darwin':
        raise SystemExit('macOS runtime measurement requires Darwin (no work performed)')
    output = args.output.absolute()
    output.mkdir(parents=True, exist_ok=False)
    roots = {VERSIONS[0]: args.old_root.absolute(), VERSIONS[1]: args.new_root.absolute()}
    compilers = {VERSIONS[0]: args.old_compiler.absolute(), VERSIONS[1]: args.new_compiler.absolute()}
    sources = roots[VERSIONS[1]]
    env = {k: v for k, v in os.environ.items() if not k.startswith('ABLA_')}
    env['LC_ALL'] = 'C'
    result = dict(architecture=platform.machine(), rounds=5, warmupsPerArm=1,
                  benchmarkSourceCommit=subprocess.check_output(
                      ['git', '-C', str(sources), 'rev-parse', 'HEAD'], text=True).strip(),
                  versions={}, programs={}, samples=[], buildSamples=[],
                  notes=['Runtime wall is Python monotonic time around time(1) + one process; '
                         'POSIX real/user/sys seconds are also retained.',
                         'Darwin time(1) peak RSS is bytes, one process per sample.',
                         'Unstripped release binaries are executed; raw and strip output sizes retained.',
                         'No affinity; same hosted runner for paired versions, not comparable across architectures.',
                         'event-http-server and https-client are size-only, matching bench-compare RUN exclusions.'])
    for version in VERSIONS:
        actual = subprocess.check_output([str(compilers[version]), '--version'], text=True).strip()
        if actual != 'ablac ' + version[1:]:
            raise ValueError((version, actual))
        result['versions'][version] = dict(compilerSha256=digest(compilers[version]),
            sysrootCommit=subprocess.check_output(['git', '-C', str(roots[version]), 'rev-parse', 'HEAD'], text=True).strip())
    (output / 'bins').mkdir()
    (output / 'logs').mkdir()
    (output / 'cache').mkdir()
    for index, (name, config) in enumerate(PROGRAMS.items()):
        result['programs'][name] = dict(source=config['source'], sourceSha256=digest(sources / config['source']),
                                       arguments=config['args'], versions={})
        for version in VERSIONS[::1 if index % 2 == 0 else -1]:
            target = output / 'bins' / f'{version}-{name}'
            log = output / 'logs' / f'build-{version}-{name}.log'
            cache = output / 'cache' / f'{version}-{name}'
            build_env = dict(env, ABLA_SYSROOT=str(roots[version]), ABLA_CACHE_DIR=str(cache),
                             ABLA_NATIVE_JOBS='4', ABLA_CODEGEN_JOBS='4')
            command = [str(compilers[version]), 'build', str(sources / config['source']),
                       '-o', str(target), '--no-cache']
            print('BUILD', version, name, flush=True)
            began = time.monotonic()
            with log.open('wb') as handle:
                completed = subprocess.run(command, cwd=sources, env=build_env, stdout=handle,
                                           stderr=subprocess.STDOUT, timeout=600, preexec_fn=stack_limit)
            result['buildSamples'].append(dict(version=version, program=name, command=command,
                                               wallSeconds=time.monotonic() - began, exit=completed.returncode))
            write_json(output / 'raw.json', result)
            if completed.returncode:
                raise RuntimeError(f'{version} {name} build failed: {log.read_text()[-3000:]}')
            stripped = target.with_name(target.name + '.stripped')
            subprocess.run(['strip', '-o', str(stripped), str(target)], check=True)
            result['programs'][name]['versions'][version] = dict(rawBytes=target.stat().st_size,
                strippedBytes=stripped.stat().st_size, binarySha256=digest(target),
                strippedSha256=digest(stripped))
            # Sidecars aren't part of the measurement artifacts.
            for sidecar in target.parent.glob(target.name + '.*'):
                if sidecar != stripped and sidecar.is_file():
                    sidecar.unlink()
    write_json(output / 'raw.json', result)
    for name, config in PROGRAMS.items():
        if config['args'] is None:
            continue
        reference = None
        for iteration in range(-1, 5):
            order = VERSIONS[::1 if iteration % 2 == 0 else -1]
            for version in order:
                binary = output / 'bins' / f'{version}-{name}'
                stem = f'{name}-{version}-' + ('warmup' if iteration == -1 else str(iteration))
                command = ['/usr/bin/time', '-l', '-p', str(binary)] + config['args']
                started = time.monotonic()
                completed = subprocess.run(command, env=env, cwd=sources, capture_output=True,
                                           timeout=180, preexec_fn=stack_limit)
                wall = time.monotonic() - started
                stdout = completed.stdout.decode('utf-8')
                stderr = completed.stderr.decode('utf-8')
                (output / 'logs' / (stem + '.stdout')).write_text(stdout)
                (output / 'logs' / (stem + '.stderr')).write_text(stderr)
                if completed.returncode:
                    raise RuntimeError(f'{stem} failed: exit {completed.returncode}: {stderr[-2000:]}')
                normal = normalized_output(name, stdout)
                if reference is None:
                    reference = normal
                    (output / 'logs' / (name + '.expected-output')).write_text(normal)
                if normal != reference:
                    raise ValueError(f'output changed in {stem}: {normal!r} != {reference!r}')
                sample = dict(program=name, version=version, round=iteration, warmup=iteration < 0,
                              wallSeconds=wall, exit=0, stdoutSha256=hashlib.sha256(completed.stdout).hexdigest(),
                              normalizedOutputSha256=hashlib.sha256(normal.encode()).hexdigest(),
                              loadAverage=list(os.getloadavg()), **time_metrics(stderr))
                result['samples'].append(sample)
                write_json(output / 'raw.json', result)
                print('RUN', stem, f'{wall:.4f}s', f'{sample["rssBytes"]}B', flush=True)
        for version in VERSIONS:
            samples = [s for s in result['samples'] if s['program'] == name and
                       s['version'] == version and not s['warmup']]
            assert len(samples) == 5
            result['programs'][name]['versions'][version]['runtime'] = {
                metric: summary([s[metric] for s in samples])
                for metric in ['wallSeconds', 'timeRealSeconds', 'userSeconds', 'systemSeconds', 'rssBytes']}
    write_json(output / 'raw.json', result)
    report = ['# Native macOS release runtime comparison', '',
              f'Architecture: `{result["architecture"]}`. v0.2.45 → v0.2.47. Five alternating runs, '
              'one warmup per arm. Median [minimum–maximum].', '',
              'Times are milliseconds; RSS is MiB (2^20 bytes); size is stripped bytes. '
              'Positive deltas mean v0.2.47 uses more. No runner/core-isolation claim.', '',
              '| Program | v045 time | v047 time | Δ | v045 RSS | v047 RSS | Δ | v045 size | v047 size | Δ |',
              '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|']
    changes = []
    for name, config in result['programs'].items():
        a, b = [config['versions'][v] for v in VERSIONS]
        percent = lambda x, y: f'{(y / x - 1) * 100:+.2f}%'
        def cell(s, factor):
            return f'{s["median"] * factor:.2f} [{s["minimum"] * factor:.2f}–{s["maximum"] * factor:.2f}]'
        fields = ['—'] * 6
        if 'runtime' in a:
            x, y = [v['runtime'] for v in (a, b)]
            fields = [cell(x['wallSeconds'], 1000), cell(y['wallSeconds'], 1000),
                      percent(x['wallSeconds']['median'], y['wallSeconds']['median']),
                      cell(x['rssBytes'], 1 / 2**20), cell(y['rssBytes'], 1 / 2**20),
                      percent(x['rssBytes']['median'], y['rssBytes']['median'])]
            changes.append(y['wallSeconds']['median'] / x['wallSeconds']['median'])
        report.append('| ' + ' | '.join([name] + fields + [str(a['strippedBytes']), str(b['strippedBytes']),
                                                        percent(a['strippedBytes'], b['strippedBytes'])]) + ' |')
    report += ['', f'Geomean of the 11 runtime median ratios: {(math.exp(statistics.mean(map(math.log, changes))) - 1) * 100:+.2f}%.',
               '', 'JSON and websocket output comparisons remove only printed timing/rate fields. '
               'All other output bytes match across every run; programs reporting MISMATCH fail the measurement.',
               '', 'These releases bundle multiple compiler and stdlib changes. The pair does not isolate allocator/root-frame effects.',
               '', 'Full commands, hashes, build logs, warmups, samples, CPU times, load averages, '
               'and unstripped sizes are retained in raw.json and logs/.']
    (output / 'report.md').write_text('\n'.join(report) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['old-root', 'new-root', 'old-compiler', 'new-compiler', 'output']:
        parser.add_argument('--' + name, type=Path, required=True)
    run(parser.parse_args())
