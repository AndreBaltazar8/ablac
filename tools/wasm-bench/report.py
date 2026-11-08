#!/usr/bin/env python3
"""Markdown tables from a bench.py run result: size, gzip size, median run time and peak memory per
program and version, each version's change against the first one."""
import json, re, statistics, sys

# report.py result.json [--skip FRACTION]: the medians drop the first FRACTION of each program's samples
# (a long run on a shared machine starts in a slower phase); the minimum is over all of them.
skip = float(sys.argv[sys.argv.index('--skip') + 1]) if '--skip' in sys.argv else 0.0
data = json.load(open(sys.argv[1]))
programs = sorted(data)
versions = sorted(next(iter(data.values())), key=lambda v: (not re.search(r'\d', v), [int(x) for x in re.findall(r'\d+', v)], v))
base = versions[0]
for p in programs:
    for v in versions:
        runs = data[p][v]['runsMs']
        data[p][v]['medianMs'] = statistics.median(runs[int(len(runs) * skip):])

def table(title, key, fmt, delta=True):
    print(f'\n### {title} (change against {base})\n')
    print('| program | ' + ' | '.join(versions) + ' |')
    print('|---|' + '---:|' * len(versions))
    for p in programs:
        cells = []
        for v in versions:
            x, b = data[p][v][key], data[p][base][key]
            cells.append(fmt(x) + ('' if v == base or not delta else f' ({(x / b - 1) * 100:+.1f}%)'))
        print(f'| {p} | ' + ' | '.join(cells) + ' |')
    if delta and len(programs) > 1:
        cells = []
        for v in versions:
            ratio = 1.0
            for p in programs:
                ratio *= data[p][v][key] / data[p][base][key]
            cells.append('' if v == base else f'{(ratio ** (1 / len(programs)) - 1) * 100:+.2f}%')
        print('| **geomean change** | ' + ' | '.join(cells) + ' |')

table('Module size (bytes)', 'bytes', lambda x: f'{x:,}')
table('Gzip size (bytes)', 'gzipBytes', lambda x: f'{x:,}')
table('Median run time (ms)' + (f', first {skip:.0%} of the rounds dropped' if skip else ''), 'medianMs', lambda x: f'{x:,.0f}')
table('Minimum run time (ms)', 'minMs', lambda x: f'{x:,.0f}')
table('Peak linear memory (bytes)', 'memoryBytes', lambda x: f'{x:,}')
print('\n### Run-time ranges (min to max, ms)\n')
print('| program | ' + ' | '.join(versions) + ' |')
print('|---|' + '---:|' * len(versions))
for p in programs:
    print(f'| {p} | ' + ' | '.join(f"{data[p][v]['minMs']:,.0f} to {data[p][v]['maxMs']:,.0f}" for v in versions) + ' |')
bad = [p for p in programs if len({data[p][v]['output'] for v in versions}) != 1]
print('\nOutputs identical across versions: ' + ('yes' if not bad else 'NO for ' + ', '.join(bad)))
