// Targeted routing/cache controls; requires the selected real Xtensa cohort (ABLA_XTENSA_LLVM_ROOT).
// Usage: node test-xtensa-routing.mjs COMPILER
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const compiler = path.resolve(process.argv[2]); // Preserve build/ablac's launcher name.
const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const selected = process.env.ABLA_XTENSA_LLVM_ROOT;
const manifest = JSON.parse(fs.readFileSync(path.join(selected, 'manifest.json'), 'utf8'));
const realOpt = fs.realpathSync(path.join(selected, 'bin/opt'));
const realLlc = fs.realpathSync(path.join(selected, 'bin/llc'));
const version = manifest.llvmVersion;
const sha = (file) => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const read = (file) => fs.readFileSync(file, 'utf8');

const root = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'abla Xtensa routing ')));
try {
    const source = path.join(root, 'probe.ab');
    fs.writeFileSync(source, '@export("probe")\nfun probe(value: int): int = (value & 255) + 7\n');
    const trace = path.join(root, 'trace.jsonl');
    const env = { ...process.env, ABLA_SYSROOT: project, ABLA_CACHE_DIR: path.join(root, 'cache'), ABLA_XTENSA_ROUTING_TRACE: trace };
    delete env.ABLA_STDLIB;
    for (const name of ['ABLA_ESP_CPU', 'ABLA_XTENSA_DIRECT_CALLS', 'ABLA_XTENSA_NARROW_BRANCHES', 'ABLA_XTENSA_TEXT_LITERALS',
        'ABLA_XTENSA_NARROW', 'ABLA_ESP_KEEP_UNWIND', 'ABLA_XTENSA_FEATURES']) delete env[name];

    const files = (directory) => fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
        const target = path.join(directory, entry.name);
        return entry.isDirectory() ? files(target) : [target];
    });

    function cohort(name) {
        const tree = path.join(root, name);
        fs.mkdirSync(path.join(tree, 'bin'), { recursive: true });
        fs.mkdirSync(path.join(tree, 'lib'));
        // Synthetic manifest/wrappers exercise the resolver; the wrappers run the actual Nix/private LLVM tools, not
        // a simulated optimizer.
        for (const [tool, real] of [['opt', realOpt], ['llc', realLlc]]) {
            const script = path.join(tree, 'bin', tool);
            fs.writeFileSync(script, `#!${process.execPath}
const fs = require("fs");
const { spawnSync } = require("child_process");
const args = process.argv.slice(2);
fs.appendFileSync(process.env.ABLA_XTENSA_ROUTING_TRACE, JSON.stringify({ tool: ${JSON.stringify(tool)}, cohort: ${JSON.stringify(name)}, args }) + "\\n");
if (args.length === 1 && args[0] === "--version" && process.env.ABLA_TEST_SWITCH_FROM === ${JSON.stringify(tree)}) {
    const link = process.env.ABLA_TEST_SWITCH_LINK;
    const next = require("path").join(require("path").dirname(link), "next-link");
    if (!fs.existsSync(next)) { fs.symlinkSync(process.env.ABLA_TEST_SWITCH_TO, next); fs.renameSync(next, link); }
}
const result = spawnSync(${JSON.stringify(real)}, args, { stdio: "inherit" });
process.exit(result.status === null ? 128 : result.status);
`);
            fs.chmodSync(script, 0o755);
        }
        fs.writeFileSync(path.join(tree, 'lib/libLLVM-test-identity'), 'Synthetic identity file; real tools use their own immutable libraries.\n');
        const data = {
            schema: 1, version: 'abla-xtensa-llvm-' + version + '-1', platform: manifest.platform, llvmVersion: version,
            sourceCommit: 'a'.repeat(40), sourceArchiveSha256: 'b'.repeat(64),
            files: Object.fromEntries(files(tree).map((p) => [path.relative(tree, p), sha(p)])),
        };
        fs.writeFileSync(path.join(tree, 'manifest.json'), JSON.stringify(data));
        return tree;
    }

    const first = cohort('first'), second = cohort('second');
    env.ABLA_XTENSA_LLVM_ROOT = first;
    const poison = path.join(root, 'poison');
    fs.mkdirSync(poison);
    for (const name of ['opt', 'llc']) {
        const p = path.join(poison, name);
        fs.writeFileSync(p, '#!/bin/sh\necho PATH_POISON_WAS_EXECUTED >&2\nexit 91\n');
        fs.chmodSync(p, 0o755);
    }
    env.PATH = poison + path.delimiter + env.PATH;

    const rows = () => (fs.existsSync(trace) ? read(trace).split('\n').filter(Boolean).map((line) => JSON.parse(line)) : []);

    function build(label, extra = [], changes = {}, expected = null) {
        const active = { ...env, ...changes };
        const command = ['build', source, '-o', path.join(root, label + '.o'), '--target-triple', 'xtensa-esp-unknown-elf',
            '--object-format', 'elf', '--emit', 'object', ...extra];
        const result = spawnSync(compiler, command, { env: active, encoding: 'utf8', timeout: 180000 });
        if (expected) assert.ok(result.status !== 0 && result.stderr.includes(expected), `${label}: ${result.status}\n${result.stdout}${result.stderr}`);
        else assert.equal(result.status, 0, `${label}\n${result.stdout}${result.stderr}`);
        assert.ok(!result.stderr.includes('PATH_POISON_WAS_EXECUTED'), result.stderr);
        return result;
    }
    const emissions = () => rows().filter((row) => row.tool === 'llc' && row.args.includes('-filetype=asm'));
    const optCalls = () => rows().filter((row) => row.tool === 'opt' && !row.args.includes('--version'));
    const buildManifest = (label) => JSON.parse(read(path.join(root, label + '.o.xtensa-tools.json')));

    build('cold');
    assert.equal(emissions().length, 1);
    let call = emissions().at(-1).args;
    assert.ok(call.includes('-mcpu=esp32') && call.includes('-relocation-model=static'));
    assert.ok(call.includes('-xtensa-direct-calls') && call.includes('-xtensa-narrow-branches'));
    assert.ok(!call.includes('-xtensa-text-section-literals'));
    let built = buildManifest('cold');
    assert.equal(built.assemblyNarrowing, true);
    assert.ok(built.stage.includes('a2fd95380faf9c54'));
    build('warm');
    assert.equal(emissions().length, 1, 'unchanged build did not hit cache');
    build('no-narrow', [], { ABLA_XTENSA_NARROW: '0' });
    assert.equal(buildManifest('no-narrow').assemblyNarrowing, false);
    assert.equal(emissions().length, 2, 'narrow opt-out reused the wrong cache entry');
    build('fast', ['--fast']);
    assert.ok(emissions().at(-1).args.includes('-O0') && emissions().at(-1).args.includes('-relocation-model=static'));
    let before = emissions().length;
    for (const [chip, cpu, feature] of [['esp32s2', 'esp32s2', null], ['esp32s3', 'esp32', '-mattr=-dfpaccel']]) {
        build(chip, [], { ABLA_ESP_CPU: chip });
        call = emissions().at(-1).args;
        assert.ok(call.includes('-mcpu=' + cpu));
        if (feature) assert.ok(call.includes(feature));
        const optCall = optCalls().at(-1).args;
        assert.ok(optCall.includes('-mcpu=' + cpu));
        if (feature) assert.ok(optCall.includes(feature));
    }
    assert.equal(emissions().length, before + 2, 'CPU/features did not invalidate cache');
    build('options', [], { ABLA_XTENSA_DIRECT_CALLS: '0', ABLA_XTENSA_NARROW_BRANCHES: '0', ABLA_XTENSA_TEXT_LITERALS: '1' });
    call = emissions().at(-1).args;
    assert.ok(!call.includes('-xtensa-direct-calls') && !call.includes('-xtensa-narrow-branches'));
    assert.ok(call.includes('-xtensa-text-section-literals'));
    before = emissions().length;
    build('feature-override', [], { ABLA_XTENSA_FEATURES: '-mul32high,+density' });
    assert.ok(emissions().at(-1).args.includes('-mattr=-mul32high,+density'));
    assert.ok(optCalls().at(-1).args.includes('-mattr=-mul32high,+density'));
    assert.equal(emissions().length, before + 1, 'feature override reused cached object');
    build('feature-warm', [], { ABLA_XTENSA_FEATURES: '-mul32high,+density' });
    assert.equal(emissions().length, before + 1, 'unchanged feature override missed cache');
    for (const invalid of ['mul32high', '-', ',+density', '+density,', '-mul32high,,+density', '-mul32high, +density', '+density\n-O0', '+bad/name']) {
        build('bad-features', [], { ABLA_XTENSA_FEATURES: invalid }, 'E_XTENSA_FEATURES');
    }
    build('badcpu', [], { ABLA_ESP_CPU: 'esp32c3' }, 'E_XTENSA_CPU');
    build('missing', [], { ABLA_XTENSA_LLVM_ROOT: path.join(root, 'missing') }, 'E_XTENSA_LLVM_MISSING');
    const savedManifest = read(path.join(first, 'manifest.json'));
    fs.writeFileSync(path.join(first, 'manifest.json'), '{ broken json');
    build('bad-json', [], {}, 'E_XTENSA_LLVM_MANIFEST');
    let data = JSON.parse(savedManifest);
    data.files['../escape'] = '0'.repeat(64);
    fs.writeFileSync(path.join(first, 'manifest.json'), JSON.stringify(data));
    build('traversal', [], {}, 'E_XTENSA_LLVM_MANIFEST');
    fs.writeFileSync(path.join(first, 'manifest.json'), savedManifest);
    const llcSaved = path.join(first, 'bin/saved-llc');
    fs.renameSync(path.join(first, 'bin/llc'), llcSaved);
    build('warm-missing-helper', [], {}, 'E_XTENSA_LLVM_FILE');
    fs.renameSync(llcSaved, path.join(first, 'bin/llc'));
    before = emissions().length;
    const lib = path.join(first, 'lib/libLLVM-test-identity');
    fs.writeFileSync(lib, read(lib) + 'ordinary replacement\n');
    build('library-replaced');
    assert.equal(emissions().length, before + 1, 'library replacement reused cached object');
    before = emissions().length;
    const script = path.join(first, 'bin/llc');
    fs.writeFileSync(script, read(script) + '// changed helper revision\n');
    build('helper-replaced');
    assert.equal(emissions().length, before + 1, 'helper replacement reused cached object');
    const held = path.join(path.dirname(lib), 'held');
    fs.renameSync(lib, held);
    build('warm-missing-library', [], {}, 'E_XTENSA_LLVM_FILE');
    fs.renameSync(held, lib);
    data = JSON.parse(read(path.join(first, 'manifest.json')));
    const original = JSON.stringify(data);
    data.platform = 'wrong-host';
    fs.writeFileSync(path.join(first, 'manifest.json'), JSON.stringify(data));
    build('badhost', [], {}, 'E_XTENSA_LLVM_HOST');
    data.platform = manifest.platform;
    data.llvmVersion = '999.0.0';
    fs.writeFileSync(path.join(first, 'manifest.json'), JSON.stringify(data));
    build('badversion', [], {}, 'E_XTENSA_LLVM_VERSION');
    fs.writeFileSync(path.join(first, 'manifest.json'), original);
    before = emissions().length;
    data.llvmVersion = version;
    data.version = data.version.slice(0, data.version.lastIndexOf('-')) + '-2';
    fs.writeFileSync(path.join(first, 'manifest.json'), JSON.stringify(data));
    build('manifest-replaced');
    assert.equal(emissions().length, before + 1, 'manifest revision reused cached object');
    const current = path.join(root, 'current');
    fs.symlinkSync(first, current);
    before = rows().length;
    build('switch-during-resolution', ['--no-cache'], {
        ABLA_XTENSA_LLVM_ROOT: current, ABLA_TEST_SWITCH_FROM: first, ABLA_TEST_SWITCH_TO: second, ABLA_TEST_SWITCH_LINK: current });
    assert.equal(fs.realpathSync(current), second);
    assert.deepEqual([...new Set(rows().slice(before).map((row) => row.cohort))], ['first'], 'selection changed during build');
    before = rows().length;
    build('next-selection', [], { ABLA_XTENSA_LLVM_ROOT: current });
    assert.deepEqual([...new Set(rows().slice(before).map((row) => row.cohort))], ['second']);
    // The SDK's GNU layout markers survive as comments in LLVM's assembler; refusing live markers prevents a silently
    // different vector layout.
    fs.writeFileSync(source, 'trusted noescape extern:"inline-assembly" fun marked(template: string, constraints: string): void\n'
        + '@export("marker_probe")\ntrusted fun probe(): void = marked("# ABLA_XTENSA_LITERAL_ISLAND", "~{memory}")\n');
    build('kept-gnu-marker', ['--no-cache'], {}, 'E_XTENSA_EXTERNAL_ASSEMBLER');
    fs.writeFileSync(source, 'trusted noescape extern:"inline-assembly" fun marked(template: string, constraints: string): void\n'
        + 'fun never(): bool = false\n'
        + '@export("plain_probe")\ntrusted fun probe(value: int): int {\n'
        + ' if (never()) marked("# ABLA_XTENSA_LITERAL_ISLAND", "~{memory}")\n'
        + ' value + 1\n}\n');
    build('dead-gnu-marker', ['--no-cache']);
    assert.ok(rows().some((row) => row.tool === 'opt' && row.args.some((arg) => arg.endsWith('.checked.ll'))), 'dead-marker control did not inspect optimized IR');
    // The ordinary host path ignores even a deliberately missing Xtensa root.
    const host = spawnSync(compiler, ['build', source, '-o', path.join(root, 'host.o'), '--emit', 'object', '--fast', '--no-cache'],
        { env: { ...env, ABLA_XTENSA_LLVM_ROOT: path.join(root, 'missing') }, encoding: 'utf8', timeout: 180000 });
    assert.equal(host.status, 0, host.stderr);
    console.log('Xtensa routing: absolute helpers, poisoned PATH, CPU/options, cache identity, warm refusals and immutable selection passed');
} finally {
    fs.rmSync(root, { recursive: true, force: true });
}
