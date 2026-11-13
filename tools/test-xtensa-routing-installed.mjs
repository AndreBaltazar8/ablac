// Actual compiler routing with a stock parent and an explicitly installed cohort.
// Usage: node test-xtensa-routing-installed.mjs PREFIX OUTPUT
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const project = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const [prefix, out] = process.argv.slice(2, 4).map((p) => path.resolve(p));
const compiler = path.join(prefix, 'bin/ablac');
const rawCompiler = path.join(prefix, 'libexec/ablac.bin');
const hosts = { 'linux/x64': 'x86_64-linux', 'darwin/arm64': 'arm64-macos', 'darwin/x64': 'x86_64-macos' };
const hostPlatform = () => hosts[`${process.platform}/${process.arch}`];
const fileSha256 = (file) => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const read = (file) => fs.readFileSync(file, 'utf8');

function run(program, args, { env, expect } = {}) {
    args = args.map(String);
    console.log('+', program, ...args);
    const result = spawnSync(program, args, { env, encoding: 'utf8', timeout: 300000, maxBuffer: 1 << 28 });
    if (expect) assert.ok(result.status !== 0 && result.stderr.includes(expect), `${args}\n${result.stdout}${result.stderr}`);
    else assert.equal(result.status, 0, `${program} ${args}\n${result.stdout}${result.stderr}`);
    return result;
}

function snapshot(root) {
    const result = {};
    const walk = (directory) => {
        for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
            const target = path.join(directory, entry.name);
            const name = path.relative(root, target);
            if (entry.isSymbolicLink()) result[name] = ['link', fs.readlinkSync(target)];
            else if (entry.isFile()) result[name] = ['file', fileSha256(target), fs.statSync(target).mode];
            else if (entry.isDirectory()) walk(target);
        }
    };
    walk(root);
    return result;
}
const natives = () => new Set((fs.existsSync(path.join(out, 'cache')) ? fs.readdirSync(path.join(out, 'cache')) : []).filter((name) => name.startsWith('native-') && name.endsWith('.o')));

const env = { ...process.env, ABLA_CACHE_DIR: path.join(out, 'cache') };
for (const name of ['ABLA_XTENSA_LLVM_ROOT', 'ABLA_STDLIB', 'ABLA_ESP_CPU', 'ABLA_XTENSA_DIRECT_CALLS', 'ABLA_XTENSA_NARROW_BRANCHES',
    'ABLA_XTENSA_TEXT_LITERALS', 'ABLA_XTENSA_NARROW', 'ABLA_ESP_KEEP_UNWIND', 'ABLA_XTENSA_FEATURES']) delete env[name];
const originals = snapshot(prefix);
run(path.join(prefix, 'bin/abla-install-xtensa'), ['--version', '23.1.3-1'], { env });
run(path.join(prefix, 'bin/abla-install-xtensa'), ['--verify'], { env });
const reference = JSON.parse(read(path.join(project, 'tests/cases/xtensa-routing/nix-objects.json')));
const results = [];
const objectArguments = (source, output) => ['build', source, '-o', output, '--target-triple', 'xtensa-esp-unknown-elf', '--object-format', 'elf', '--emit', 'object'];
for (const entry of reference.objects) {
    const source = path.join(project, entry.source);
    assert.equal(fileSha256(source), entry.sourceSha256);
    const output = path.join(out, entry.name + '.o');
    const active = { ...env, ABLA_ESP_CPU: entry.cpu, ABLA_XTENSA_NARROW: entry.narrow ? '1' : '0' };
    const args = [...objectArguments(source, output), '--no-cache', '--no-debug'];
    if (entry.fast) args.push('--fast');
    run(compiler, args, { env: active });
    const actual = fileSha256(output);
    assert.equal(actual, entry.sha256, `${entry.name} ${actual} ${entry.sha256}`);
    results.push({ name: entry.name, sha256: actual });
}
// A distinct process and output name cannot introduce a temporary FILE symbol.
{
    const entry = reference.objects[0];
    const repeat = path.join(out, 'different-process-output.o');
    run(compiler, [...objectArguments(path.join(project, entry.source), repeat), '--no-cache', '--no-debug'],
        { env: { ...env, ABLA_ESP_CPU: entry.cpu, ABLA_XTENSA_NARROW: entry.narrow ? '1' : '0' } });
    assert.equal(fileSha256(repeat), entry.sha256, 'output path or PID changed object bytes');
}
// Without the launcher, poison both PATH tools. Automatic selection must still derive the same installed cohort from
// the actual compiler image.
const poison = path.join(out, 'poison');
fs.mkdirSync(poison);
for (const name of ['opt', 'llc']) {
    const file = path.join(poison, name);
    fs.writeFileSync(file, '#!/bin/sh\necho XTENSA_PATH_POISON >&2\nexit 91\n');
    fs.chmodSync(file, 0o755);
}
const active = { ...env, PATH: poison + path.delimiter + env.PATH, ABLA_SYSROOT: path.join(prefix, 'share/abla') };
const intrinsics = objectArguments(path.join(project, 'tests/cases/xtensa-routing/intrinsics.ab'), path.join(out, 'poison-proof.o'));
run(rawCompiler, intrinsics, { env: active });
const keys = natives();
run(rawCompiler, intrinsics, { env: active });
assert.deepEqual([...natives()].sort(), [...keys].sort(), 'warm installed build missed cache');
// A real library-only identity change must invalidate cache even though its content and --version output are unchanged.
// Restore the owned file metadata (touch -r keeps the nanoseconds).
const current = path.join(prefix, 'lib/abla/xtensa-llvm/current');
const cohortRoot = fs.realpathSync(current);
const library = fs.readdirSync(path.join(cohortRoot, 'lib')).filter((name) => name.startsWith('libLLVM')).sort().map((name) => path.join(cohortRoot, 'lib', name))[0];
const saved = path.join(out, 'library.timestamps');
fs.writeFileSync(saved, '');
run('touch', ['-r', library, saved]);
const old = fs.statSync(library);
try {
    fs.utimesSync(library, old.atimeMs / 1000, old.mtimeMs / 1000 + 1);
    run(rawCompiler, intrinsics, { env: active });
    const changed = natives();
    assert.equal([...changed].filter((name) => !keys.has(name)).length, 1, 'real library identity reused cached object');
} finally {
    run('touch', ['-r', saved, library]);
}
// A warm cache cannot conceal a missing selected cohort.
const held = path.join(path.dirname(current), 'held-current');
fs.renameSync(current, held);
try {
    run(rawCompiler, intrinsics, { env: active, expect: 'E_XTENSA_LLVM_MISSING' });
} finally {
    fs.renameSync(held, current);
}
// The synthetic wrapper tests still execute the real private LLVM tools.
active.ABLA_XTENSA_LLVM_ROOT = fs.realpathSync(current);
run(process.execPath, [path.join(project, 'tools/test-xtensa-routing.mjs'), rawCompiler], { env: active });
// Parent files remain unchanged, including its ordinary tools and libraries.
const after = snapshot(prefix);
assert.ok(Object.entries(originals).every(([name, value]) => JSON.stringify(after[name]) === JSON.stringify(value)), 'parent toolchain was modified');
const report = {
    status: 'passed', platform: hostPlatform(), parentHasXtensa: read(path.join(out, 'parent-llc-version.txt')).includes('xtensa '),
    parentHasPrivateXtensaOptions: false, unchangedParentEntries: Object.keys(originals).length, objects: results,
    poisonedPathPassed: true, missingWarmCohortRejected: true, realLibraryIdentityInvalidatedCache: true,
};
fs.writeFileSync(path.join(out, 'result.json'), JSON.stringify(report, null, 2) + '\n');
console.log(JSON.stringify(report, null, 2));
