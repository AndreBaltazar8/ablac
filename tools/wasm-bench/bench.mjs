// Wasm size and Node run time of the perf benchmark programs across released compilers.
//
//     node tools/wasm-bench/bench.mjs build RELEASES OUT [--versions v0.2.45,...] [--progs fib,...] [--extra name:path]
//     node tools/wasm-bench/bench.mjs run OUT [--rounds N] [--warmup N] [--pin CPU] [--json result.json] [--versions ..] [--progs ..]
//
// RELEASES holds one directory per version: <version>/ablac-x86_64-linux and <version>/stdlib (the release tag's stdlib,
// which is what that compiler builds against). `build` compiles every program for each version into
// OUT/<version>/<program>.wasm with `#wasmBuildModule` (a release module), and `run` instantiates each module in a fresh
// Node process, `rounds` times after `warmup` rounds that are not kept, alternating the order of versions every round,
// and keeps every sample, so a summary can drop the early rounds of a long run. Sizes are exact and need no rounds.
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const PROGRAMS = 'fib sieve nbody trees strings maps dispatch matrix'.split(' ');
const driver = (name, source, out) => `import "abla/wasm/build"
val built = #wasmBuildModule("${name}", "${source}", "${out}", false, false)
fun main: int = if (built) 0 else 1
`;

const [command, ...rest] = process.argv.slice(2);
const positional = [];
const options = { rounds: 7, warmup: 1, pin: '4', json: '', versions: '', progs: '', extra: [] };
for (let i = 0; i < rest.length; i++) {
    if (rest[i].startsWith('--')) {
        const key = rest[i].slice(2);
        const value = rest[++i];
        if (key === 'extra') options.extra.push(value);
        else options[key] = ['rounds', 'warmup'].includes(key) ? Number(value) : value;
    } else positional.push(rest[i]);
}
const median = (values) => { const s = [...values].sort((a, b) => a - b); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
const listVersions = (directory) => (options.versions ? options.versions.split(',') : fs.readdirSync(directory).filter((d) => d.startsWith('v0.2.')).sort());

function build() {
    const [releases, out] = positional;
    const extras = Object.fromEntries(options.extra.map((x) => [x.slice(0, x.indexOf(':')), x.slice(x.indexOf(':') + 1)]));
    const programs = options.progs ? options.progs.split(',') : PROGRAMS;
    for (const version of listVersions(releases)) {
        const release = path.resolve(releases, version);
        const target = path.resolve(out, version);
        fs.mkdirSync(target, { recursive: true });
        const env = { ...process.env, ABLA_SYSROOT: release };
        for (const name of programs) {
            const work = path.join(target, 'work-' + name);
            fs.mkdirSync(work, { recursive: true });
            // The build macro compiles a source inside the project directory.
            fs.copyFileSync(extras[name] ?? path.join(ROOT, 'tests/benchmarks/perf', name + '.ab'), path.join(work, 'program.ab'));
            fs.writeFileSync(path.join(work, 'abla.toml'), 'compileCapabilities = ["filesystem.write"]\n');
            fs.writeFileSync(path.join(work, 'build.ab'), driver(name, 'program.ab', name + '.wasm'));
            for (const cmd of [[path.join(release, 'ablac-x86_64-linux'), 'build', 'build.ab', '-o', 'driver', '--no-cache'], ['./driver']]) {
                const r = spawnSync(cmd[0], cmd.slice(1), { cwd: work, env, encoding: 'utf8', maxBuffer: 1 << 28 });
                if (r.status !== 0) { console.error(`${version} ${name}: ${cmd.join(' ')} failed\n${(r.stdout + r.stderr).slice(-2000)}`); process.exit(1); }
            }
            fs.renameSync(path.join(work, name + '.wasm'), path.join(target, name + '.wasm'));
            console.log('built', version, name, fs.statSync(path.join(target, name + '.wasm')).size);
        }
    }
}

function run() {
    const [out] = positional;
    const versions = listVersions(out);
    const wanted = options.progs ? options.progs.split(',') : PROGRAMS;
    const programs = wanted.filter((p) => versions.every((v) => fs.existsSync(path.join(out, v, p + '.wasm'))));
    const runner = path.join(ROOT, 'tools/wasm-bench/run.mjs');
    const result = {};
    for (const name of programs) {
        const samples = Object.fromEntries(versions.map((v) => [v, []]));
        const outputs = {}, memory = {};
        for (let round = 0; round < options.rounds + options.warmup; round++) { // the first `warmup` rounds are kept out
            const order = round % 2 === 0 ? versions : [...versions].reverse();
            for (const v of order) {
                const r = spawnSync('taskset', ['-c', options.pin, 'node', runner, path.join(out, v, name + '.wasm')], { encoding: 'utf8', timeout: 300000, maxBuffer: 1 << 28 });
                if (r.status !== 0) { console.error(`${v} ${name}: ${r.stderr.slice(-1000)}`); process.exit(1); }
                const lines = r.stdout.trim().split('\n');
                const data = JSON.parse(lines[lines.length - 1]);
                if ((outputs[v] ??= data.output) !== data.output) {
                    console.error(`${v} ${name}: round ${round} printed ${JSON.stringify(data.output)}, the first round ${JSON.stringify(outputs[v])}`);
                    process.exit(1);
                }
                memory[v] = data.memoryBytes;
                if (round >= options.warmup) samples[v].push(data.runMs);
            }
        }
        result[name] = {};
        for (const v of versions) {
            const wasm = fs.readFileSync(path.join(out, v, name + '.wasm'));
            result[name][v] = {
                bytes: wasm.length, gzipBytes: zlib.gzipSync(wasm, { level: 9 }).length,
                medianMs: median(samples[v]), minMs: Math.min(...samples[v]), maxMs: Math.max(...samples[v]),
                memoryBytes: memory[v], runsMs: samples[v], output: outputs[v],
            };
        }
        console.log(name, Object.fromEntries(versions.map((v) => [v, Math.round(result[name][v].medianMs * 10) / 10])));
    }
    if (options.json) {
        const sortKeys = (x) => (Array.isArray(x) || x === null || typeof x !== 'object' ? x : Object.fromEntries(Object.keys(x).sort().map((k) => [k, sortKeys(x[k])])));
        fs.writeFileSync(options.json, JSON.stringify(sortKeys(result), null, 1));
    }
}

if (command === 'build') build();
else if (command === 'run') run();
else { console.error('usage: bench.mjs build RELEASES OUT | run OUT'); process.exit(2); }
