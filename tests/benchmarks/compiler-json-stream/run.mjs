// Opt-in end-to-end comparison for the compiler's streaming JSON migration.
// Runs only in an otherwise idle, owned worktree. Restores three production
// files between variants and always restores the candidate on normal failure.
import fs from 'node:fs';
import path from 'node:path';
import assert from 'node:assert/strict';
import { spawnSync, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const [mode, directory, ...args] = process.argv.slice(2);
assert.ok(directory, 'prepare DIR BEFORE_COMPILER AFTER_COMPILER BASE_REF | pair DIR INDEX | summary DIR');
const out = path.resolve(directory);
assert.ok(out.startsWith(path.join(root, 'build') + path.sep), 'artifacts must be inside this worktree/build');
const wasmOutput = path.join(out, 'project', 'output');
const files = ['src/sourcemap.ab', 'src/analysis_service.ab', 'stdlib/abla/json/entry.ab'];
const sha = bytes => createHash('sha256').update(bytes).digest('hex');
const manifestPath = path.join(out, 'manifest.json');
const writeJson = (file, value) => fs.writeFileSync(file, JSON.stringify(value, null, 2) + '\n');
const hashFile = file => sha(fs.readFileSync(file));
const median = values => [...values].sort((a, b) => a - b)[Math.floor(values.length / 2)];

if (mode === 'prepare') {
    const [before, after, ref] = args;
    assert.ok(before && after && ref);
    fs.mkdirSync(out); // A new artifact directory; never overwrite earlier evidence.
    for (const name of ['before', 'after', 'self', 'project', 'oracle']) fs.mkdirSync(path.join(out, name));
    const sources = files.map((file, index) => {
        const a = execFileSync('git', ['show', `${ref}:${file}`], { cwd: root });
        const b = fs.readFileSync(path.join(root, file));
        fs.writeFileSync(path.join(out, 'before', `${index}.ab`), a);
        fs.writeFileSync(path.join(out, 'after', `${index}.ab`), b);
        return { file, before: sha(a), after: sha(b) };
    });
    for (const [name, compiler] of [['before', before], ['after', after]]) {
        const target = path.join(out, name, 'input.bin');
        fs.copyFileSync(path.resolve(compiler), target);
        fs.chmodSync(target, 0o755);
    }
    let source = '// café 😀: JSON escapes "quote" \\ slash\n';
    for (let i = 0; i < 1024; i++) source += `@noinline\nfun item${i}(value: int): int {\n    val a = value + ${i}\n    val b = a + 1\n    val c = b * 3\n    val d = c - a\n    a + b + c + d\n}\n`;
    source += 'fun main: int {\n    var sum = 0\n';
    for (let i = 0; i < 1024; i++) source += `    sum = sum + item${i}(1)\n`;
    source += '    sum\n}\n';
    const project = path.join(out, 'project');
    fs.mkdirSync(wasmOutput);
    fs.writeFileSync(path.join(project, 'main.ab'), source);
    fs.writeFileSync(path.join(project, 'abla.toml'), 'name = "json-dogfood-bench"\nentry = "main.ab"\n');
    const module = path.join(wasmOutput, 'module.wasm');
    fs.writeFileSync(path.join(project, 'build.ab'), `import "abla/wasm/build"\nval built = #wasmBuildModule("json-dogfood-bench", "main.ab", ${JSON.stringify(module)}, true, false)\nfun main: int = if (built) 0 else 1\n`);
    const input = [
        { schema: 1, id: 1, method: 'initialize', params: { workspaceRoots: [project], clientName: 'json-dogfood-bench', clientVersion: '1', analysisMode: 'graph-v2' } },
        { schema: 1, id: 2, method: 'analyze', params: { roots: [path.join(project, 'main.ab')] } },
        { schema: 1, id: 3, method: 'shutdown', params: {} },
    ].map(line => JSON.stringify(line)).join('\n') + '\n';
    fs.writeFileSync(path.join(out, 'analyze.jsonl'), input);
    const manifest = {
        base: execFileSync('git', ['rev-parse', ref], { cwd: root, encoding: 'utf8' }).trim(),
        candidate: execFileSync('git', ['rev-parse', 'HEAD'], { cwd: root, encoding: 'utf8' }).trim(),
        sources, projectSha256: sha(Buffer.from(source)),
        compilers: Object.fromEntries(['before', 'after'].map(name => [name, hashFile(path.join(out, name, 'input.bin'))])),
    };
    writeJson(manifestPath, manifest);
    console.log(JSON.stringify(manifest));
} else if (mode === 'pair') {
    const index = Number(args[0]);
    assert.ok(Number.isInteger(index) && index >= -1 && index < 9);
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    for (const source of manifest.sources) assert.equal(hashFile(path.join(root, source.file)), source.after, `candidate changed: ${source.file}`);
    const metricsPath = path.join(out, 'metrics.jsonl');
    const previous = fs.existsSync(metricsPath) ? fs.readFileSync(metricsPath, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse) : [];
    assert.ok(!previous.some(row => row.pair === index), 'pair already has evidence; use a new directory after a partial failure');
    const restore = name => manifest.sources.forEach((source, i) => fs.copyFileSync(path.join(out, name, `${i}.ab`), path.join(root, source.file)));
    for (const signal of ['SIGTERM', 'SIGINT']) process.on(signal, () => { restore('after'); process.exit(signal === 'SIGTERM' ? 143 : 130); });
    const oracle = (name, data) => {
        const target = path.join(out, 'oracle', name);
        if (fs.existsSync(target)) assert.ok(data.equals(fs.readFileSync(target)), `output changed: ${name}`);
        else fs.writeFileSync(target, data);
        return { bytes: data.length, sha256: sha(data) };
    };
    const run = (variant, phase, command, arguments_, input, env = {}) => {
        const stats = path.join(out, `${index}.${variant}.${phase}.time`);
        // Optional PMU counters accompany the same alternating workload; the
        // caller selects events suitable for its pinned CPU type.
        const perf = process.env.JSON_STREAM_PERF;
        const counters = path.join(out, `${index}.${variant}.${phase}.perf.tsv`);
        const measuredCommand = perf || command;
        const measuredArguments = perf ? ['stat', '-x', '\t', '-e',
            process.env.JSON_STREAM_PERF_EVENTS || 'cycles:u,instructions:u',
            '-o', counters, '--', command, ...arguments_] : arguments_;
        const start = process.hrtime.bigint();
        const result = spawnSync('time', ['-f', '%U\t%S\t%M', '-o', stats, measuredCommand, ...measuredArguments], {
            cwd: root, input, maxBuffer: 256 * 1024 * 1024,
            env: { ...process.env, ABLA_SYSROOT: root, ABLA_DEBUG: '0', ABLA_COMPILE_EVAL: 'auto', ...env },
        });
        const elapsedNs = Number(process.hrtime.bigint() - start);
        fs.writeFileSync(path.join(out, `${index}.${variant}.${phase}.stderr`), result.stderr ?? '');
        assert.ifError(result.error);
        assert.equal(result.status, 0, `${variant} ${phase}: ${result.stderr?.toString()}`);
        const [userSeconds, systemSeconds, peakKiB] = fs.readFileSync(stats, 'utf8').trim().split(/\s+/).map(Number);
        return { pair: index, variant, phase, elapsedNs, userSeconds, systemSeconds, peakKiB,
            ...(perf ? { perfCounters: path.basename(counters) } : {}), stdout: result.stdout };
    };
    const record = row => {
        const { stdout, ...metrics } = row;
        fs.appendFileSync(metricsPath, JSON.stringify(metrics) + '\n');
        console.log(JSON.stringify(metrics));
    };
    try {
        for (const variant of (index % 2 === 0 ? ['before', 'after'] : ['after', 'before'])) {
            restore(variant);
            const compiler = path.join(out, variant, index === -1 ? 'input.bin' : 'stage2.bin');
            const bitcode = path.join(out, 'self', 'latest.bc');
            const output = path.join(out, 'self', 'compiler.bin');
            const built = run(variant, 'self', 'bash', ['tools/build-self-hosted-current.sh', compiler, output, 'src/orc_main.ab'], undefined, { ABLA_COMPILER_BITCODE: bitcode });
            const expectedBitcode = path.join(out, variant, 'stage2.bc');
            if (index === -1) {
                fs.copyFileSync(output, path.join(out, variant, 'stage2.bin'));
                fs.chmodSync(path.join(out, variant, 'stage2.bin'), 0o755);
                fs.copyFileSync(bitcode, expectedBitcode);
            } else assert.ok(fs.readFileSync(bitcode).equals(fs.readFileSync(expectedBitcode)), `${variant}: stage2/stage3 bitcode differs`);
            record({ ...built, bitcodeSha256: hashFile(bitcode) });
            const stage2 = path.join(out, variant, 'stage2.bin');
            const analyzed = run(variant, 'analyze', stage2, ['analyze', '--stdio'], fs.readFileSync(path.join(out, 'analyze.jsonl')));
            const answer = JSON.parse(analyzed.stdout.toString().trim().split('\n')[1]);
            const count = answer.result.documents.reduce((sum, doc) => sum + doc.occurrences.length, 0);
            assert.ok(count > 15000, `expected occurrence-heavy analysis, got ${count}`);
            record({ ...analyzed, occurrences: count, ...oracle('analyze.jsonl', analyzed.stdout) });
            for (const file of ["module.wasm", "module.wasm.map", "module.wasm.debug.wasm"]) fs.rmSync(path.join(wasmOutput, file), { force: true });
            const wasm = run(variant, 'wasm', stage2, ['build', path.join(out, 'project', 'build.ab'), '-o', path.join(wasmOutput, 'driver'), '--no-cache'], undefined, { ABLA_DEBUG: '1' });
            const driver = spawnSync(path.join(wasmOutput, 'driver'), [], { cwd: root });
            assert.ifError(driver.error);
            assert.equal(driver.status, 0, 'Wasm build driver reports failure');
            const artifacts = {};
            for (const file of ['module.wasm', 'module.wasm.map', 'module.wasm.debug.wasm']) artifacts[file] = oracle(file, fs.readFileSync(path.join(wasmOutput, file)));
            record({ ...wasm, artifacts });
        }
    } finally { restore('after'); }
} else if (mode === 'summary') {
    const rows = fs.readFileSync(path.join(out, 'metrics.jsonl'), 'utf8').trim().split('\n').map(JSON.parse).filter(row => row.pair >= 0);
    for (const phase of ['self', 'analyze', 'wasm']) {
        const ratios = [];
        let beforeTotal = 0, afterTotal = 0;
        for (let i = 0; i < 9; i++) {
            const before = rows.find(row => row.pair === i && row.phase === phase && row.variant === 'before');
            const after = rows.find(row => row.pair === i && row.phase === phase && row.variant === 'after');
            assert.ok(before && after, `incomplete ${phase} pair ${i}`);
            ratios.push(before.elapsedNs / after.elapsedNs);
            beforeTotal += before.elapsedNs;
            afterTotal += after.elapsedNs;
        }
        console.log(JSON.stringify({ phase, pairs: 9, fasterPairs: ratios.filter(ratio => ratio >= 1).length, pairedMedian: median(ratios), aggregate: beforeTotal / afterTotal, ratios }));
    }
} else throw new Error(`unknown mode: ${mode}`);
