#!/usr/bin/env python3
"""Wasm size and Node run time of the perf benchmark programs across released compilers.

    tools/wasm-bench/bench.py build RELEASES OUT [--versions v0.2.45,...] [--progs fib,...]
    tools/wasm-bench/bench.py run OUT [--rounds N] [--pin CPU] [--json result.json]

RELEASES holds one directory per version: <version>/ablac-x86_64-linux and <version>/stdlib (the
release tag's stdlib, which is what that compiler builds against). `build` compiles every program
for each version into OUT/<version>/<program>.wasm with `#wasmBuildModule` (a release module), and
`run` instantiates each module in a fresh Node process, `rounds` times after `warmup` rounds that are not kept, alternating the order of
versions every round, and keeps every sample, so a summary can drop the early rounds of a long run. Sizes are exact and need no rounds."""
import argparse, gzip, json, os, shutil, statistics, subprocess, sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PROGRAMS = 'fib sieve nbody trees strings maps dispatch matrix'.split()
DRIVER = '''import "abla/wasm/build"
val built = #wasmBuildModule("%(name)s", "%(source)s", "%(out)s", false, false)
fun main: int = if (built) 0 else 1
'''

def build(args):
    extras = dict(x.split(':', 1) for x in args.extra)
    versions = args.versions.split(',') if args.versions else sorted(d for d in os.listdir(args.releases) if d.startswith('v0.2.'))
    programs = args.progs.split(',') if args.progs else PROGRAMS
    for version in versions:
        release = os.path.abspath(os.path.join(args.releases, version))
        out = os.path.abspath(os.path.join(args.out, version))
        os.makedirs(out, exist_ok=True)
        env = dict(os.environ, ABLA_SYSROOT=release)
        for name in programs:
            work = os.path.join(out, 'work-' + name)
            os.makedirs(work, exist_ok=True)
            # The build macro compiles a source inside the project directory.
            shutil.copy(extras.get(name) or os.path.join(ROOT, 'tests/benchmarks/perf', name + '.ab'), os.path.join(work, 'program.ab'))
            with open(os.path.join(work, 'abla.toml'), 'w') as f:
                f.write('compileCapabilities = ["filesystem.write"]\n')
            with open(os.path.join(work, 'build.ab'), 'w') as f:
                f.write(DRIVER % dict(name=name, source='program.ab', out=name + '.wasm'))
            for step in (['build', 'build.ab', '-o', 'driver', '--no-cache'], None):
                cmd = [os.path.join(release, 'ablac-x86_64-linux')] + step if step else ['./driver']
                r = subprocess.run(cmd, cwd=work, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                if r.returncode != 0:
                    sys.exit(f'{version} {name}: {" ".join(cmd)} failed\n' + r.stdout.decode(errors='replace')[-2000:])
            shutil.move(os.path.join(work, name + '.wasm'), os.path.join(out, name + '.wasm'))
            print('built', version, name, os.path.getsize(os.path.join(out, name + '.wasm')), flush=True)

def run(args):
    versions = args.versions.split(',') if args.versions else sorted(d for d in os.listdir(args.out) if d.startswith('v0.2.'))
    programs = [p for p in (args.progs.split(',') if args.progs else PROGRAMS) if all(os.path.exists(os.path.join(args.out, v, p + '.wasm')) for v in versions)]
    runner = os.path.join(ROOT, 'tools/wasm-bench/run.mjs')
    result = {}
    for name in programs:
        samples = {v: [] for v in versions}
        outputs = {}
        memory = {}
        for round_ in range(args.rounds + args.warmup):  # the first `warmup` rounds are kept out
            order = versions if round_ % 2 == 0 else versions[::-1]
            for v in order:
                cmd = ['taskset', '-c', args.pin, 'node', runner, os.path.join(args.out, v, name + '.wasm')]
                r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=300)
                if r.returncode != 0:
                    sys.exit(f'{v} {name}: {r.stderr.decode(errors="replace")[-1000:]}')
                data = json.loads(r.stdout.decode().strip().splitlines()[-1])
                if outputs.setdefault(v, data['output']) != data['output']:
                    sys.exit(f'{v} {name}: round {round_} printed {data["output"]!r}, the first round {outputs[v]!r}')
                memory[v] = data['memoryBytes']
                if round_ >= args.warmup:
                    samples[v].append(data['runMs'])
        for v in versions:
            wasm = open(os.path.join(args.out, v, name + '.wasm'), 'rb').read()
            result.setdefault(name, {})[v] = dict(
                bytes=len(wasm), gzipBytes=len(gzip.compress(wasm, 9)),
                medianMs=statistics.median(samples[v]), minMs=min(samples[v]), maxMs=max(samples[v]),
                memoryBytes=memory[v], runsMs=samples[v], output=outputs[v])
        print(name, {v: round(result[name][v]['medianMs'], 1) for v in versions}, flush=True)
    if args.json:
        with open(args.json, 'w') as f:
            json.dump(result, f, indent=1, sort_keys=True)

p = argparse.ArgumentParser()
sub = p.add_subparsers(dest='cmd', required=True)
b = sub.add_parser('build'); b.add_argument('releases'); b.add_argument('out')
b.add_argument('--versions', default=''); b.add_argument('--progs', default='')
b.add_argument('--extra', action='append', default=[], help='name:path of a program outside tests/benchmarks/perf')
r = sub.add_parser('run'); r.add_argument('out'); r.add_argument('--rounds', type=int, default=7)
r.add_argument('--pin', default='4'); r.add_argument('--json', default='')
r.add_argument('--versions', default=''); r.add_argument('--progs', default='')
r.add_argument('--warmup', type=int, default=1, help='rounds run first and not kept (a shared machine needs several)')
a = p.parse_args()
build(a) if a.cmd == 'build' else run(a)
