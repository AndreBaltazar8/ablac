// Explicit CI-only frozen firmware gate through a real installed companion.
// Usage: node test-xtensa-embedded-installed.mjs PREFIX EMBEDDED_SOURCE OUTPUT
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { fingerprint } from './xtensa-elf-fingerprint.mjs';

assert.equal(process.env.GITHUB_ACTIONS, 'true', 'installed embedded probe is CI-only');
assert.equal(process.platform, 'linux', 'this capacity probe requires Linux');
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const [prefix, embedded, out] = process.argv.slice(2, 5).map((p) => path.resolve(p));
const reference = JSON.parse(fs.readFileSync(path.join(root, 'tests/cases/xtensa-routing/firmware-reference.json'), 'utf8'));
const sha256 = (data) => createHash('sha256').update(data).digest('hex');
const sh = (command, args, options = {}) => spawnSync(command, args, { encoding: 'utf8', ...options });
const actual = sh('git', ['-c', 'safe.directory=' + embedded, '-C', embedded, 'rev-parse', 'HEAD']).stdout.trim();
assert.equal(actual, reference.revision);
const entry = path.join(embedded, reference.entry);
assert.equal(sha256(fs.readFileSync(entry)), reference.entrySha256);
assert.equal(sh('which', ['prlimit']).status, 0, '4 GiB address-space enforcement requires prlimit');
assert.ok(fs.statSync('/usr/bin/time', { throwIfNoEntry: false })?.isFile(), 'capacity probe requires GNU time');
// The first four CPUs this process may use, for every child (sched_setaffinity before).
const allowed = sh('taskset', ['-cp', String(process.pid)]).stdout.trim().split(':').pop().trim().split(',').flatMap((part) => {
    const [a, b] = part.trim().split('-').map(Number);
    return Array.from({ length: (b ?? a) - a + 1 }, (_, i) => a + i);
}).sort((x, y) => x - y).slice(0, 4);
const pinned = (command, args) => ['taskset', ['-c', allowed.join(','), command, ...args]];

// Run the actual firmware compiler path without the SDK wrapper's independent llc/llvm-mc self-test: that wrapper requires
// the full patched developer LLVM, while the companion deliberately supplies only opt, llc and libLLVM.
const compiler = path.join(root, 'tools/run-limited-compiler.sh');
const env = {
    ...process.env, ABLA_COMPILER_PAYLOAD: path.join(prefix, 'libexec/ablac.bin'), ABLA_SYSROOT: path.join(prefix, 'share/abla'),
    ABLA_MAX_MEMORY_MB: '4096', ABLA_NATIVE_JOBS: '4', JOBS: '4', ABLA_CACHE_DIR: path.join(out, 'embedded-cache'),
    PATH: path.join(prefix, 'bin') + path.delimiter + process.env.PATH,
};
for (const name of ['ABLA_STDLIB', 'ABLA_XTENSA_LLVM_ROOT', 'ABLA_ESP_CPU', 'ABLA_XTENSA_NARROW', 'ABLA_XTENSA_DIRECT_CALLS',
    'ABLA_XTENSA_NARROW_BRANCHES', 'ABLA_XTENSA_TEXT_LITERALS', 'ABLA_ESP_KEEP_UNWIND', 'ABLA_XTENSA_FEATURES']) delete env[name];
const timing = path.join(out, 'embedded-check-time.json');
const narrow = path.join(out, 'embedded-firmware-narrow-build.o');
const buildArguments = (output) => ['build', entry, '--target-triple', 'xtensa-esp-unknown-elf', '--object-format', 'elf', '--emit', 'object', '--no-cache', '-o', output];
{
    const log = fs.openSync(path.join(out, 'embedded-check-source.log'), 'w');
    const [program, args] = pinned('/usr/bin/time', ['-f', '{"peakKiB":%M,"wallSeconds":%e}', '-o', timing, compiler, ...buildArguments(narrow)]);
    const result = spawnSync(program, args, { cwd: embedded, env, stdio: ['ignore', log, log], timeout: 1800000 });
    fs.closeSync(log);
    assert.equal(result.status, 0, 'firmware build failed');
}
console.log(fs.readFileSync(path.join(out, 'embedded-check-source.log'), 'utf8'));
const measurements = JSON.parse(fs.readFileSync(timing, 'utf8'));
assert.ok(measurements.peakKiB < 4096 * 1024, JSON.stringify(measurements));

function verify(file, kind) {
    const expected = reference.objects[kind];
    const raw = fs.readFileSync(file);
    const digest = sha256(raw);
    assert.equal(raw.length, expected.bytes, `${kind} ${raw.length} ${expected.bytes}`);
    if (kind === 'narrow') {
        assert.equal(digest, expected.sha256, kind);
    } else {
        // Only explicit RELA-covered L32R immediates may differ from direct object emission; source opcode/register
        // bytes stay exact.
        assert.deepEqual(fingerprint(raw, true), expected.relocationMasked, kind);
    }
    fs.copyFileSync(file, path.join(out, `embedded-firmware-${kind}.o`));
    const manifest = JSON.parse(fs.readFileSync(file + '.xtensa-tools.json', 'utf8'));
    assert.equal(manifest.assemblyNarrowing, kind === 'narrow');
    const cohort = fs.realpathSync(path.join(prefix, 'lib/abla/xtensa-llvm/current'));
    assert.ok(manifest.identity.includes(cohort));
    assert.ok(manifest.identity.includes('a254932917786ca006920fcb8ec02f3c5556dd06'));
    return {
        kind, bytes: raw.length, sha256: digest, stage: manifest.stage,
        comparison: kind === 'narrow' ? 'whole-object' : 'L32R fields masked plus normalized RELA',
        linkedCheck: 'unavailable: companion intentionally has no GNU firmware linker',
    };
}

const objects = [verify(narrow, 'narrow')];
const wide = path.join(out, 'embedded-firmware-wide-build.o');
assert.equal(spawnSync(compiler, buildArguments(wide), { cwd: embedded, env: { ...env, ABLA_XTENSA_NARROW: '0' }, stdio: 'inherit', timeout: 600000 }).status, 0);
objects.push(verify(wide, 'wide'));
assert.equal(spawnSync(path.join(prefix, 'bin/abla-install-xtensa'), ['--verify'], { env, stdio: 'inherit', timeout: 120000 }).status, 0);
const result = JSON.parse(fs.readFileSync(path.join(out, 'result.json'), 'utf8'));
result.embedded = {
    status: 'passed', revision: actual, limitMiB: 4096, peakMetric: 'GNU time %M: largest single process, not summed children',
    ...measurements, objects,
};
fs.writeFileSync(path.join(out, 'result.json'), JSON.stringify(result, null, 2) + '\n');
console.log(JSON.stringify(result.embedded, null, 2));
