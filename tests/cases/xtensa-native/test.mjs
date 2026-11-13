// The native Xtensa installer (tools/xtensa-native) against fixture archives: install, verify, activation and
// rollback, a failing helper, a corrupted archive, a 0700 published root, and how the entry finds its root.
// Usage: node test.mjs INSTALLER FIXTURE_DIRECTORY
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import zlib from 'node:zlib';

const binary = path.resolve(process.argv[2]);
const base = path.resolve(process.argv[3]);
fs.mkdirSync(base, { recursive: true });
const hosts = { Linux: 'x86_64-linux', Darwin: { arm64: 'arm64-macos', x64: 'x86_64-macos' }[process.arch] };
const host = hosts[{ linux: 'Linux', darwin: 'Darwin' }[process.platform]];
assert.ok(host, `${process.platform} ${process.arch}`);
const version = '23.1.3-1';
const tag = 'abla-xtensa-llvm-' + version;
const sha = (x) => createHash('sha256').update(x).digest('hex');

// A USTAR archive of the given members, as Python's tarfile wrote them: owner 0, time 0, mode 0755 under bin/.
function ustar(members) {
    const blocks = [];
    for (const [name, data, mode] of members) {
        const header = Buffer.alloc(512);
        header.write(name, 0, 100, 'latin1');
        header.write(mode.toString(8).padStart(7, '0') + '\0', 100);
        header.write('0000000\0', 108);
        header.write('0000000\0', 116);
        header.write(data.length.toString(8).padStart(11, '0') + '\0', 124);
        header.write('00000000000\0', 136);
        header.write('        ', 148);
        header.write('0', 156);
        header.write('ustar\0' + '00', 257);
        let sum = 0;
        for (const byte of header) sum += byte;
        header.write(sum.toString(8).padStart(6, '0') + '\0 ', 148);
        blocks.push(header, data, Buffer.alloc((512 - (data.length % 512)) % 512));
    }
    blocks.push(Buffer.alloc(1024));
    return Buffer.concat(blocks);
}

function fixture(name, helper) {
    const root = path.join(base, name);
    fs.mkdirSync(path.join(root, 'libexec'), { recursive: true });
    fs.writeFileSync(path.join(root, 'libexec/ablac.bin'), 'compiler');
    const files = { 'bin/opt': helper, 'bin/llc': helper, 'lib/libLLVM.test': Buffer.from('private') };
    // Sorted keys and two-space indent, as the installer's own output is.
    const manifest = Buffer.from(JSON.stringify({
        files: Object.fromEntries(Object.entries(files).sort(([a], [b]) => (a < b ? -1 : 1)).map(([k, v]) => [k, sha(v)])),
        llvmVersion: '23.1.3', platform: host, schema: 1, sourceArchiveSha256: 'b'.repeat(64), sourceCommit: 'a'.repeat(40), version: tag,
    }, null, 2) + '\n');
    const members = [...Object.entries(files), ['manifest.json', manifest]]
        .map(([p, data]) => [`${tag}-${host}/${p}`, data, p.startsWith('bin/') ? 0o755 : 0o644]);
    const archive = zlib.gzipSync(ustar(members));
    const archivePath = path.join(base, name + '.tar.gz');
    fs.writeFileSync(archivePath, archive);
    const platforms = Object.fromEntries(['x86_64-linux', 'arm64-macos', 'x86_64-macos'].map((h) => [h, {
        url: `https://github.com/AndreBaltazar8/llvm-project/releases/download/${tag}/${tag}-${h}.tar.gz`, sha256: sha(archive), manifestSha256: sha(manifest) }]));
    const catalog = { schema: 1, releases: { [version]: { status: 'published', llvmVersion: '23.1.3', sourceCommit: 'a'.repeat(40), sourceArchiveSha256: 'b'.repeat(64), platforms } } };
    const catalogPath = path.join(base, name + '.json');
    fs.writeFileSync(catalogPath, JSON.stringify(catalog));
    return [root, archivePath, catalogPath];
}

const spawn = (program, args) => spawnSync(program, args.map(String), { encoding: 'utf8', timeout: 60000 });
function run(root, catalog, ...args) {
    const success = typeof args.at(-1) === 'object' ? args.pop().success : true;
    const result = spawn(binary, ['--toolchain-root', root, '--catalog', catalog, ...args]);
    assert.equal(result.status === 0, success, `${args}: ${result.status}\n${result.stdout}${result.stderr}`);
    return result;
}
const failing = { success: false };

assert.equal(spawn(binary, ['-h']).status, 0);
for (const flag of ['--verify=1', '--help=1']) assert.notEqual(spawn(binary, [flag]).status, 0);

const good = "#!/bin/sh\nprintf '%s\\n' 'LLVM version 23.1.3' 'Registered Targets: xtensa'\n";
const [root, archive, catalog] = fixture('good', Buffer.from(good));
run(root, catalog, '--version', version, '--archive', archive);
const parent = path.join(root, 'lib/abla/xtensa-llvm');
assert.equal(fs.readlinkSync(path.join(parent, 'current')), version);
run(root, catalog, '--verify');
// The packaged entry is a symlink to libexec; root discovery must follow it.
fs.mkdirSync(path.join(root, 'bin'));
fs.copyFileSync(binary, path.join(root, 'libexec/abla-install-xtensa-native'));
fs.chmodSync(path.join(root, 'libexec/abla-install-xtensa-native'), fs.statSync(binary).mode);
fs.symlinkSync('../libexec/abla-install-xtensa-native', path.join(root, 'bin/abla-install-xtensa-native'));
let result = spawn(path.join(root, 'bin/abla-install-xtensa-native'), ['--catalog', catalog, '--verify']);
assert.equal(result.status, 0, result.stdout + result.stderr);
const external = path.join(base, 'external-bin');
fs.mkdirSync(external);
fs.symlinkSync(path.join(root, 'bin/abla-install-xtensa-native'), path.join(external, 'installer'));
result = spawn(path.join(external, 'installer'), ['--catalog', catalog, '--verify']);
assert.equal(result.status, 0, result.stdout + result.stderr);
result = spawn(path.join(root, 'bin/abla-install-xtensa-native'), ['--catalog=' + catalog, '--verify']);
assert.equal(result.status, 0, result.stdout + result.stderr);
run(root, catalog, '--version', version, '--archive', path.join(base, 'missing'));
assert.equal(fs.readlinkSync(path.join(parent, 'current')), version);
// A 0700 published root is incomplete: neither verification nor installation may accept it or change the active link.
fs.unlinkSync(path.join(parent, 'current'));
fs.symlinkSync('old', path.join(parent, 'current'));
fs.chmodSync(path.join(parent, version), 0o700);
for (const args of [['--verify', '--version', version], ['--version', version, '--archive', archive]]) {
    result = run(root, catalog, ...args, failing);
    assert.ok(result.stderr.includes('publication_in_progress'), result.stderr);
    assert.equal(fs.readlinkSync(path.join(parent, 'current')), 'old');
}
fs.chmodSync(path.join(parent, version), 0o555);
fs.unlinkSync(path.join(parent, 'current'));
fs.symlinkSync(version, path.join(parent, 'current'));
// A validly pinned archive with a failing helper must not publish or activate.
const [badRoot, badArchive, badCatalog] = fixture('bad-helper', Buffer.from('#!/bin/sh\nexit 1\n'));
const badParent = path.join(badRoot, 'lib/abla/xtensa-llvm');
fs.mkdirSync(badParent, { recursive: true });
fs.symlinkSync('old', path.join(badParent, 'current'));
result = run(badRoot, badCatalog, '--version', version, '--archive', badArchive, failing);
assert.ok(result.stderr.includes('helper exit'), result.stderr);
assert.equal(fs.readlinkSync(path.join(badParent, 'current')), 'old');
assert.deepEqual(fs.readdirSync(badParent).sort(), ['current']);
// A corrupted archive fails the pin before decompression or activation.
const [hashRoot, hashArchive, hashCatalog] = fixture('bad-hash', Buffer.from(good));
fs.writeFileSync(hashArchive, Buffer.concat([fs.readFileSync(hashArchive), Buffer.from('x')]));
result = run(hashRoot, hashCatalog, '--version', version, '--archive', hashArchive, failing);
assert.ok(result.stderr.includes('archive_hash'), result.stderr);
assert.ok(!fs.existsSync(path.join(hashRoot, 'lib/abla/xtensa-llvm/current')));
run(root, catalog, '--verify', '--archive', archive, failing);
console.log('native Xtensa installer: install, verify, activation and rollback passed');
