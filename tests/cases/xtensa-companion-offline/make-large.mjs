// A controlled archive whose compressed size exceeds the old 128 MiB cap (stored gzip blocks around 129 MiB of 'x').
// Usage: node make-large.mjs DIRECTORY
import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import zlib from 'node:zlib';

const out = path.resolve(process.argv[2]);
const size = 129 * 1024 * 1024;
const sha = (x) => createHash('sha256').update(x).digest('hex');
const large = Buffer.alloc(size, 'x');
const files = { 'bin/opt': Buffer.from('opt'), 'bin/llc': Buffer.from('llc') };
const manifest = {
    files: { 'bin/llc': sha(files['bin/llc']), 'bin/opt': sha(files['bin/opt']), 'lib/libLLVM.test': sha(large) },
    llvmVersion: '23.1.3', platform: 'x86_64-linux', schema: 1, sourceArchiveSha256: 'b'.repeat(64), sourceCommit: 'a'.repeat(40),
    version: 'abla-xtensa-llvm-23.1.3-1',
};
const raw = Buffer.from(JSON.stringify(manifest) + '\n');
const prefix = 'abla-xtensa-llvm-23.1.3-1-x86_64-linux/';

function header(name, length, mode) {
    const block = Buffer.alloc(512);
    block.write(name, 0, 100, 'latin1');
    block.write(mode.toString(8).padStart(7, '0') + '\0', 100);
    block.write('0000000\0', 108);
    block.write('0000000\0', 116);
    block.write(length.toString(8).padStart(11, '0') + '\0', 124);
    block.write('00000000000\0', 136);
    block.write('        ', 148);
    block.write('0', 156);
    block.write('ustar\0' + '00', 257);
    let total = 0;
    for (const byte of block) total += byte;
    block.write(total.toString(8).padStart(6, '0') + '\0 ', 148);
    return block;
}
const padding = (length) => Buffer.alloc((512 - (length % 512)) % 512);
const parts = [];
for (const [name, data] of [...Object.entries(files), ['manifest.json', raw]]) {
    parts.push(header(prefix + name, data.length, name.startsWith('bin/') ? 0o755 : 0o644), data, padding(data.length));
}
parts.push(header(prefix + 'lib/libLLVM.test', size, 0o644), large, padding(size), Buffer.alloc(1024));
const archive = zlib.gzipSync(Buffer.concat(parts), { level: 0 });
fs.writeFileSync(path.join(out, 'large.tar.gz'), archive);
assert.ok(archive.length > 128 * 1024 * 1024);
fs.writeFileSync(path.join(out, 'large.json'), JSON.stringify({
    version: '23.1.3-1', platform: 'x86_64-linux', llvmVersion: '23.1.3', sourceCommit: 'a'.repeat(40), sourceArchiveSha256: 'b'.repeat(64),
    archiveSha256: sha(archive), manifestSha256: sha(raw),
}));
