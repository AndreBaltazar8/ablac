// Check exact-match and metadata/code mismatch controls on a real Mach-O asset.
// Usage: node test-macos-binary-comparison.mjs MACHO_FILE
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { compare, inventory } from './compare-macos-binaries.mjs';

const source = path.resolve(process.argv[2]);
const [original, info] = inventory(source);
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'abla-macos-compare-'));
try {
    assert.equal(compare(source, source, path.join(root, 'exact'), { quiet: true }), 0);
    const uuid = info.loadCommands.find((command) => command.command === '0x1b');
    const text = info.sections.find((section) => section.name === '__TEXT,__text');
    const controls = [['uuid', uuid.offset + 8, 'load command'], ['code', text.offset, 'section']];
    const signature = info.loadCommands.find((command) => command.command === '0x1d');
    if (signature) controls.push(['signature', signature.fileData.offset + signature.fileData.bytes - 1, 'link-edit data']);
    for (const [label, offset, region] of controls) {
        const data = Buffer.from(original);
        data[offset] ^= 1;
        const changed = path.join(root, label + '.macho');
        fs.writeFileSync(changed, data);
        assert.equal(compare(source, changed, path.join(root, label), { quiet: true }), 1);
        const report = JSON.parse(fs.readFileSync(path.join(root, label, 'comparison.json'), 'utf8'));
        assert.ok(!report.rawEqual && report.cmpStatus === 1);
        assert.equal(report.firstDifferentByte, offset);
        assert.equal(report.publishedLocation.region, region, JSON.stringify(report));
        if (label === 'code') assert.ok(report.differentSections.some((row) => row.name === '__TEXT,__text'));
        else assert.equal(report.differentFunctionCount, 0);
        console.log(`Mach-O comparator: rejects ${label} mutation at ${offset}`);
    }
    assert.ok(fs.readFileSync(source).equals(original));
    console.log('Mach-O comparator: exact match and all deliberate mismatches passed');
} finally {
    fs.rmSync(root, { recursive: true, force: true });
}
