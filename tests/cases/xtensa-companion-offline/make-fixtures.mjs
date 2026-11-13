// The offline installer's fixtures: one good archive with its pins, and a bad one per fault (identity, extra file, file
// hash, raw path, mode, archive hash, manifest hash, many files, truncated gzip, damaged tar, wrong root), plus a sparse
// file over the archive limit. Usage: node make-fixtures.mjs DIRECTORY
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';
import { ustar } from './ustar.mjs';

const directory = path.resolve(process.argv[2]);
fs.mkdirSync(directory, { recursive: true });
const version = '23.1.3-1', host = 'x86_64-linux', root = `abla-xtensa-llvm-${version}-${host}`;
const files = { 'bin/opt': Buffer.from('opt'), 'bin/llc': Buffer.from('llc'), 'lib/libLLVM.test': Buffer.from('library') };
const sha = (x) => createHash('sha256').update(x).digest('hex');
const sorted = (object) => Object.fromEntries(Object.entries(object).sort(([a], [b]) => (a < b ? -1 : 1)));

function make(name, change) {
    const contents = { ...files };
    if (change === 'many') for (let i = 0; i < 150; i++) contents[`extra/f${String(i).padStart(3, '0')}`] = Buffer.from('x');
    const manifest = {
        schema: 1, version: 'abla-xtensa-llvm-' + version, platform: host, llvmVersion: '23.1.3', sourceCommit: 'a'.repeat(40),
        sourceArchiveSha256: 'b'.repeat(64), files: Object.fromEntries(Object.entries(contents).map(([k, v]) => [k, sha(v)])),
    };
    if (change === 'identity') manifest.platform = 'arm64-macos';
    manifest.files = sorted(manifest.files);
    const raw = Buffer.from(JSON.stringify(sorted(manifest), null, 2) + '\n');
    const members = [...Object.entries(contents), ['manifest.json', raw], ...(change === 'extra' ? [['extra', Buffer.from('x')]] : [])]
        .map(([entry, data]) => {
            if (change === 'filehash' && entry === 'bin/opt') data = Buffer.from('bad');
            const prefix = change === 'rawpath' ? './' : '';
            const chosen = change === 'wrongroot' ? 'wrong-root' : root;
            const mode = change === 'mode' ? 0o644 : entry.startsWith('bin/') ? 0o755 : 0o644;
            return [prefix + chosen + '/' + entry, data, mode];
        });
    let tar = ustar(members);
    if (change === 'tarbad') { tar = Buffer.from(tar); tar[0] ^= 1; }
    let archive = zlib.gzipSync(tar);
    if (change === 'gzipbad') archive = archive.subarray(0, archive.length - 1);
    const config = {
        version, platform: host, llvmVersion: '23.1.3', sourceCommit: 'a'.repeat(40), sourceArchiveSha256: 'b'.repeat(64),
        archiveSha256: sha(archive), manifestSha256: sha(raw),
    };
    if (change === 'archivehash') config.archiveSha256 = '0'.repeat(64);
    if (change === 'manifesthash') config.manifestSha256 = '0'.repeat(64);
    fs.writeFileSync(path.join(directory, name + '.tar.gz'), archive);
    fs.writeFileSync(path.join(directory, name + '.json'), JSON.stringify(config));
}

for (const name of ['good', 'identity', 'extra', 'filehash', 'rawpath', 'mode', 'archivehash', 'manifesthash', 'many', 'gzipbad', 'tarbad', 'wrongroot']) {
    make(name, name === 'good' ? undefined : name);
}
const descriptor = fs.openSync(path.join(directory, 'oversize.tar.gz'), 'w');
fs.ftruncateSync(descriptor, 536870913);
fs.closeSync(descriptor);
