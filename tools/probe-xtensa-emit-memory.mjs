// Manual CI diagnosis, not a timing/peak pass gate; compare two frozen revisions.
// Usage (CI only, from the repository root): node tools/probe-xtensa-emit-memory.mjs
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

assert.equal(process.env.GITHUB_ACTIONS, 'true', 'memory probe is manual CI only');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const out = path.join(root, 'build/xtensa-emit-memory');
fs.mkdirSync(out, { recursive: true });
const refs = { old: 'dffc60aab1dfd844707f328d5bad0667e68fc1aa', new: '13ddb261f96d7cabad176abb737a9ddc319276ae' };

function check(result, what) {
    if (result.status !== 0) throw new Error(`${what}: ${result.status ?? result.signal}`);
    return result;
}
// The first four of the CPUs this process may use; every child runs on them (taskset), as sched_setaffinity did.
const allowed = (() => {
    const text = check(spawnSync('taskset', ['-cp', String(process.pid)], { encoding: 'utf8' }), 'taskset').stdout;
    const list = text.trim().split(':').pop().trim();
    return list.split(',').flatMap((part) => {
        const [a, b] = part.trim().split('-').map(Number);
        return Array.from({ length: (b ?? a) - a + 1 }, (_, i) => a + i);
    }).sort((x, y) => x - y);
})();
const cpus = allowed.slice(0, 4);
const pinned = (command, args) => ['taskset', ['-c', cpus.join(','), command, ...args]];
function run(command, args, options = {}) {
    const [program, programArgs] = pinned(command, args);
    return spawnSync(program, programArgs, { cwd: root, stdio: 'inherit', ...options });
}

check(run('git', ['fetch', '--no-tags', '--depth=1', 'origin', ...Object.values(refs)]), 'git fetch');
const snapshots = {};
for (const [name, ref] of Object.entries(refs)) {
    const destination = path.join(out, 'source-' + name);
    fs.mkdirSync(destination, { recursive: true });
    const archive = path.join(out, name + '.tar');
    const descriptor = fs.openSync(archive, 'w');
    try { check(run('git', ['archive', ref, 'src'], { stdio: ['ignore', descriptor, 'inherit'] }), 'git archive'); } finally { fs.closeSync(descriptor); }
    check(run('tar', ['-xf', archive, '-C', destination]), 'tar');
    snapshots[name] = path.join(destination, 'src');
}
const bootstrap = path.join(out, 'bootstrap.bin');
check(run(path.join(root, 'tools/bootstrap-compiler.sh'), [bootstrap]), 'bootstrap-compiler');
const env = { ...process.env, ABLA_SYSROOT: root, ABLA_MAX_MEMORY_MB: '4096', ABLA_MAX_SECONDS: '1800' };
const rows = [];
const compilers = {};
const source = path.join(root, 'src');
const saved = path.join(out, 'original-src');
assert.ok(fs.statSync(source).isDirectory() && !fs.lstatSync(source).isSymbolicLink() && !fs.existsSync(saved));
fs.renameSync(source, saved);

function activate(name) {
    fs.rmSync(source, { recursive: true, force: true }); // Only a copy made by this invocation, never saved.
    fs.cpSync(snapshots[name], source, { recursive: true });
}

function measure(sourceName, compilerName, round, pressure) {
    const stem = `${sourceName}-${compilerName}-${round}-` + (pressure ? 'loaded' : 'idle');
    const timing = path.join(out, stem + '.time'), errors = path.join(out, stem + '.err');
    const active = {
        ...env, ABLA_COMPILER_PAYLOAD: compilers[compilerName], ABLA_NATIVE_JOBS: '1', ABLA_CODEGEN_JOBS: '1',
        ABLA_COMPILER_MEMORY_TRACE: '1', ABLA_CACHE_DIR: path.join(out, stem + '-cache'),
    };
    const stdout = fs.openSync(path.join(out, 'current.ll'), 'w'), stderr = fs.openSync(errors, 'w');
    try {
        check(run('/usr/bin/env', ['time', '-f', '%M %e', '-o', timing, path.join(root, 'tools/run-limited-compiler.sh'), '--emit-llvm', path.join(source, 'orc_main.ab')],
            { env: active, stdio: ['ignore', stdout, stderr], timeout: 1810000 }), 'emit-llvm');
    } finally { fs.closeSync(stdout); fs.closeSync(stderr); }
    const [peak, wall] = fs.readFileSync(timing, 'utf8').split(/\s+/).filter(Boolean);
    const live = {};
    for (const line of fs.readFileSync(errors, 'utf8').split('\n')) {
        if (line.startsWith('abla-ir-memory ') || line.startsWith('abla-llvm-memory ')) {
            const at = line.lastIndexOf(' ');
            live[line.slice(0, at)] = Number(line.slice(at + 1));
        }
    }
    const ir = fs.readFileSync(path.join(out, 'current.ll'));
    const row = {
        source: sourceName, compiler: compilerName, round, pressure, peakKiB: Number(peak), wallSeconds: Number(wall), liveByPhase: live,
        irBytes: ir.length, irSha256: createHash('sha256').update(ir).digest('hex'),
    };
    rows.push(row);
    fs.writeFileSync(path.join(out, 'samples.json'), JSON.stringify(rows, null, 2) + '\n');
    const { liveByPhase, ...shown } = row;
    console.log(JSON.stringify(shown));
}

const median = (values) => { const s = [...values].sort((a, b) => a - b); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
try {
    for (const name of Object.keys(refs)) {
        activate(name);
        const compiler = path.join(out, `compiler-${name}.bin`);
        const active = { ...env, ABLA_COMPILER_PAYLOAD: bootstrap, ABLA_NATIVE_JOBS: '4', ABLA_CODEGEN_JOBS: '4' };
        check(run(path.join(root, 'tools/run-limited-compiler.sh'), ['build', path.join(source, 'orc_main.ab'), '--no-cache', '-o', compiler], { env: active, timeout: 1810000 }), 'build');
        compilers[name] = compiler;
    }
    for (const sourceName of Object.keys(refs)) {
        activate(sourceName);
        for (let round = 0; round < 3; round++) {
            for (const compilerName of round % 2 === 0 ? ['old', 'new'] : ['new', 'old']) measure(sourceName, compilerName, round, false);
        }
    }
    // Reproduce CPU contention within the same four-core affinity, without introducing other compiler heaps. Keep these
    // owned children joined.
    activate('new');
    const hogs = Array.from({ length: Math.min(3, cpus.length - 1) }, () => {
        const [program, args] = pinned(process.execPath, ['-e', 'while (true) {}']);
        return spawn(program, args, { stdio: 'ignore' });
    });
    try {
        for (let round = 0; round < 3; round++) {
            for (const compilerName of round % 2 === 0 ? ['old', 'new'] : ['new', 'old']) measure('new', compilerName, round, true);
        }
    } finally {
        for (const hog of hogs) hog.kill('SIGTERM');
    }
} finally {
    fs.rmSync(source, { recursive: true, force: true });
    fs.renameSync(saved, source);
}

const summary = [];
for (const sourceName of Object.keys(refs)) {
    for (const compilerName of Object.keys(refs)) {
        for (const pressure of [false, true]) {
            const peaks = rows.filter((row) => row.source === sourceName && row.compiler === compilerName && row.pressure === pressure).map((row) => row.peakKiB);
            if (peaks.length) summary.push({ source: sourceName, compiler: compilerName, pressure, medianKiB: median(peaks), minKiB: Math.min(...peaks), maxKiB: Math.max(...peaks) });
        }
    }
}
const result = { status: 'measured', refs, cpus, summary };
fs.writeFileSync(path.join(out, 'result.json'), JSON.stringify(result, null, 2) + '\n');
console.log(JSON.stringify(result, null, 2));
