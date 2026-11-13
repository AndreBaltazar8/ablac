// Measure released macOS programs; no production compiler/runtime changes.
//
// Each compiler uses its own release-tag stdlib. Both compile the same frozen benchmark sources. Warm up once, then
// alternate five process-level runs per arm. Darwin time(1) reports peak RSS in bytes. No CPU-affinity or
// hardware-counter claim: hosted GitHub runners are noisy and macOS chooses the core.
//
// node tools/bench-macos-runtime.mjs --old-root D --new-root D --old-compiler F --new-compiler F --output DIR
//     [--old-version v0.2.45] [--new-version v0.2.47]
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { performance } from 'node:perf_hooks';
import { pathToFileURL } from 'node:url';

const PROGRAMS = {};
for (const name of 'fib sieve nbody trees strings maps dispatch matrix'.split(' ')) PROGRAMS[name] = { source: `tests/benchmarks/perf/${name}.ab`, args: [] };
Object.assign(PROGRAMS, {
    'websocket-codec': { source: 'tests/benchmarks/websocket-codec.ab', args: [] },
    'json-readers': { source: 'tests/benchmarks/json-readers.ab', args: ['3000', '100'] },
    'json-megabyte': { source: 'tests/benchmarks/json-megabyte.ab', args: ['30000'] },
    'event-http-server': { source: 'examples/event-http-server.ab', args: null },
    'https-client': { source: 'examples/https-client.ab', args: null },
});

const sha256 = (data) => createHash('sha256').update(data).digest('hex');
const digest = (file) => sha256(fs.readFileSync(file));
const median = (values) => { const s = [...values].sort((a, b) => a - b); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };

export function timeMetrics(stderr) {
    const result = {};
    for (const [label, key] of [['real', 'timeRealSeconds'], ['user', 'userSeconds'], ['sys', 'systemSeconds']]) {
        const matches = [...stderr.matchAll(new RegExp('^' + label + '\\s+(\\d+(?:\\.\\d+)?)\\s*$', 'gm'))];
        if (!matches.length) throw new Error(`missing Darwin time metric ${label}`);
        result[key] = Number(matches.at(-1)[1]);
    }
    const matches = [...stderr.matchAll(/^\s*(\d+)\s+maximum resident set size\s*$/gm)];
    if (!matches.length) throw new Error('missing Darwin time peak RSS');
    result.rssBytes = Number(matches.at(-1)[1]);
    return result;
}

export function normalizedOutput(name, output) {
    if (output.includes('MISMATCH')) throw new Error(`${name} reports MISMATCH`);
    if (name === 'json-readers') output = output.replace(/\d+(?:\.\d+)? ns\/field/g, '<time> ns/field');
    else if (name === 'json-megabyte') output = output.replace(/: \d+ ms \(\d+ MB\/s\)/g, ': <time> ms (<rate> MB/s)');
    else if (name === 'websocket-codec') output = output.replace(/ in \d+ms/g, ' in <time>ms');
    return output;
}

export function summary(values) {
    const m = median(values);
    return { median: m, minimum: Math.min(...values), maximum: Math.max(...values), spreadPercent: m ? (Math.max(...values) - Math.min(...values)) / m * 100 : null };
}

const writeJson = (file, value) => fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
const git = (root, ...args) => {
    const r = spawnSync('git', ['-C', root, ...args], { encoding: 'utf8' });
    if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr}`);
    return r.stdout.trim();
};
const signed = (x, digits = 2) => (x >= 0 ? '+' : '-') + Math.abs(x).toFixed(digits);
const machine = () => (process.arch === 'x64' ? 'x86_64' : process.arch);

function run(args) {
    const VERSIONS = [args.oldVersion, args.newVersion];
    const short = VERSIONS.map((version) => version.replaceAll('v0.2.', 'v0').replaceAll('.', ''));
    if (process.platform !== 'darwin') { console.error('macOS runtime measurement requires Darwin (no work performed)'); process.exit(1); }
    const output = path.resolve(args.output);
    fs.mkdirSync(path.dirname(output), { recursive: true }); // parents, like the Python mkdir(parents=True)
    fs.mkdirSync(output); // not recursive-existing
    const roots = { [VERSIONS[0]]: path.resolve(args.oldRoot), [VERSIONS[1]]: path.resolve(args.newRoot) };
    const compilers = { [VERSIONS[0]]: path.resolve(args.oldCompiler), [VERSIONS[1]]: path.resolve(args.newCompiler) };
    const sources = roots[VERSIONS[1]];
    const env = Object.fromEntries(Object.entries(process.env).filter(([k]) => !k.startsWith('ABLA_')));
    env.LC_ALL = 'C';
    const result = {
        architecture: machine(), rounds: 5, warmupsPerArm: 1, benchmarkSourceCommit: git(sources, 'rev-parse', 'HEAD'), versions: {}, programs: {}, samples: [], buildSamples: [],
        notes: ['Runtime wall is monotonic time around time(1) + one process; POSIX real/user/sys seconds are also retained.',
            'Darwin time(1) peak RSS is bytes, one process per sample.',
            'Unstripped release binaries are executed; raw and strip output sizes retained.',
            'No affinity; same hosted runner for paired versions, not comparable across architectures.',
            'event-http-server and https-client are size-only, matching bench-compare RUN exclusions.'],
    };
    for (const version of VERSIONS) {
        const r = spawnSync(compilers[version], ['--version'], { encoding: 'utf8' });
        if (r.status !== 0) throw new Error(`${version}: --version failed`);
        const actual = r.stdout.trim();
        if (actual !== 'ablac ' + version.slice(1)) throw new Error(`${version} ${actual}`);
        result.versions[version] = { compilerSha256: digest(compilers[version]), sysrootCommit: git(roots[version], 'rev-parse', 'HEAD') };
    }
    for (const directory of ['bins', 'logs', 'cache']) fs.mkdirSync(path.join(output, directory));
    Object.entries(PROGRAMS).forEach(([name, config], index) => {
        result.programs[name] = { source: config.source, sourceSha256: digest(path.join(sources, config.source)), arguments: config.args, versions: {} };
        for (const version of index % 2 === 0 ? VERSIONS : [...VERSIONS].reverse()) {
            const target = path.join(output, 'bins', `${version}-${name}`);
            const log = path.join(output, 'logs', `build-${version}-${name}.log`);
            const cache = path.join(output, 'cache', `${version}-${name}`);
            const buildEnv = {
                ...env, ABLA_SYSROOT: roots[version], ABLA_CACHE_DIR: cache, ABLA_NATIVE_JOBS: '4', ABLA_CODEGEN_JOBS: '4',
                ABLA_COMPILER_PAYLOAD: compilers[version], ABLA_MAX_SECONDS: '600',
            };
            const command = [path.join(roots[version], 'tools/run-limited-compiler.sh'), 'build', path.join(sources, config.source), '-o', target, '--no-cache'];
            console.log('BUILD', version, name);
            const began = performance.now();
            const handle = fs.openSync(log, 'w');
            let completed;
            try {
                completed = spawnSync(command[0], command.slice(1), { cwd: sources, env: buildEnv, stdio: ['ignore', handle, handle], timeout: 660000 });
            } finally { fs.closeSync(handle); }
            const exit = completed.status ?? -1;
            result.buildSamples.push({ version, program: name, command, wallSeconds: (performance.now() - began) / 1000, exit });
            writeJson(path.join(output, 'raw.json'), result);
            if (exit) throw new Error(`${version} ${name} build failed: ${fs.readFileSync(log, 'utf8').slice(-3000)}`);
            const stripped = target + '.stripped';
            if (spawnSync('strip', ['-o', stripped, target]).status !== 0) throw new Error('strip failed');
            result.programs[name].versions[version] = {
                rawBytes: fs.statSync(target).size, strippedBytes: fs.statSync(stripped).size, binarySha256: digest(target), strippedSha256: digest(stripped),
            };
            // Sidecars aren't part of the measurement artifacts.
            for (const entry of fs.readdirSync(path.dirname(target))) {
                const sidecar = path.join(path.dirname(target), entry);
                if (entry.startsWith(path.basename(target) + '.') && sidecar !== stripped && fs.statSync(sidecar).isFile()) fs.unlinkSync(sidecar);
            }
        }
    });
    writeJson(path.join(output, 'raw.json'), result);
    for (const [name, config] of Object.entries(PROGRAMS)) {
        if (config.args === null) continue;
        let reference = null;
        for (let iteration = -1; iteration < 5; iteration++) {
            const order = iteration % 2 === 0 ? VERSIONS : [...VERSIONS].reverse();
            for (const version of order) {
                const binary = path.join(output, 'bins', `${version}-${name}`);
                const stem = `${name}-${version}-` + (iteration === -1 ? 'warmup' : String(iteration));
                const command = ['/usr/bin/time', '-l', '-p', binary, ...config.args];
                const started = performance.now();
                const completed = spawnSync(command[0], command.slice(1), { env, cwd: sources, encoding: 'utf8', timeout: 180000, maxBuffer: 1 << 28 });
                const wall = (performance.now() - started) / 1000;
                const stdout = completed.stdout ?? '', stderr = completed.stderr ?? '';
                fs.writeFileSync(path.join(output, 'logs', stem + '.stdout'), stdout);
                fs.writeFileSync(path.join(output, 'logs', stem + '.stderr'), stderr);
                if (completed.status !== 0) throw new Error(`${stem} failed: exit ${completed.status}: ${stderr.slice(-2000)}`);
                const normal = normalizedOutput(name, stdout);
                if (reference === null) {
                    reference = normal;
                    fs.writeFileSync(path.join(output, 'logs', name + '.expected-output'), normal);
                }
                if (normal !== reference) throw new Error(`output changed in ${stem}: ${JSON.stringify(normal)} != ${JSON.stringify(reference)}`);
                const sample = {
                    program: name, version, round: iteration, warmup: iteration < 0, wallSeconds: wall, exit: 0,
                    stdoutSha256: sha256(Buffer.from(stdout)), normalizedOutputSha256: sha256(Buffer.from(normal)), loadAverage: os.loadavg(), ...timeMetrics(stderr),
                };
                result.samples.push(sample);
                writeJson(path.join(output, 'raw.json'), result);
                console.log('RUN', stem, `${wall.toFixed(4)}s`, `${sample.rssBytes}B`);
            }
        }
        for (const version of VERSIONS) {
            const samples = result.samples.filter((s) => s.program === name && s.version === version && !s.warmup);
            assert.equal(samples.length, 5);
            result.programs[name].versions[version].runtime = Object.fromEntries(
                ['wallSeconds', 'timeRealSeconds', 'userSeconds', 'systemSeconds', 'rssBytes'].map((metric) => [metric, summary(samples.map((s) => s[metric]))]));
        }
    }
    writeJson(path.join(output, 'raw.json'), result);
    const report = ['# Native macOS release runtime comparison', '',
        `Architecture: \`${result.architecture}\`. ${VERSIONS[0]} → ${VERSIONS[1]}. Five alternating runs, one warmup per arm. Median [minimum–maximum].`, '',
        'Times are milliseconds; RSS is MiB (2^20 bytes); size is stripped bytes. '
        + `Positive deltas mean ${VERSIONS[1]} uses more. No runner/core-isolation claim.`, '',
        `| Program | ${short[0]} time | ${short[1]} time | Δ | ${short[0]} RSS | ${short[1]} RSS | Δ | ${short[0]} size | ${short[1]} size | Δ |`,
        '|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|'];
    const changes = [];
    const percent = (x, y) => `${signed((y / x - 1) * 100)}%`;
    const cell = (s, factor) => `${(s.median * factor).toFixed(2)} [${(s.minimum * factor).toFixed(2)}–${(s.maximum * factor).toFixed(2)}]`;
    for (const [name, config] of Object.entries(result.programs)) {
        const [a, b] = VERSIONS.map((v) => config.versions[v]);
        let fields = Array(6).fill('—');
        if ('runtime' in a) {
            const [x, y] = [a, b].map((v) => v.runtime);
            fields = [cell(x.wallSeconds, 1000), cell(y.wallSeconds, 1000), percent(x.wallSeconds.median, y.wallSeconds.median),
                cell(x.rssBytes, 1 / 2 ** 20), cell(y.rssBytes, 1 / 2 ** 20), percent(x.rssBytes.median, y.rssBytes.median)];
            changes.push(y.wallSeconds.median / x.wallSeconds.median);
        }
        report.push('| ' + [name, ...fields, String(a.strippedBytes), String(b.strippedBytes), percent(a.strippedBytes, b.strippedBytes)].join(' | ') + ' |');
    }
    const geomean = Math.exp(changes.map(Math.log).reduce((p, q) => p + q, 0) / changes.length);
    report.push('', `Geomean of the 11 runtime median ratios: ${signed((geomean - 1) * 100)}%.`,
        '', 'JSON and websocket output comparisons remove only printed timing/rate fields. '
        + 'All other output bytes match across every run; programs reporting MISMATCH fail the measurement.',
        '', 'These releases bundle multiple compiler and stdlib changes. The pair does not isolate allocator/root-frame effects.',
        '', 'Full commands, hashes, build logs, warmups, samples, CPU times, load averages, and unstripped sizes are retained in raw.json and logs/.');
    fs.writeFileSync(path.join(output, 'report.md'), report.join('\n') + '\n');
}

function main(argv) {
    const args = { oldVersion: 'v0.2.45', newVersion: 'v0.2.47' };
    const required = ['old-root', 'new-root', 'old-compiler', 'new-compiler', 'output'];
    for (let i = 0; i < argv.length; i++) {
        const key = argv[i].replace(/^--/, '');
        const camel = key.replace(/-([a-z])/g, (_, c) => c.toUpperCase());
        if (![...required, 'old-version', 'new-version'].includes(key)) { console.error(`unknown argument ${argv[i]}`); process.exit(2); }
        args[camel] = argv[++i];
    }
    for (const key of required) {
        if (!args[key.replace(/-([a-z])/g, (_, c) => c.toUpperCase())]) { console.error(`--${key} is required`); process.exit(2); }
    }
    run(args);
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) main(process.argv.slice(2));
