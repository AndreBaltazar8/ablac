// The pins of the cached real companion release, from tools/xtensa-companions.json, as the test program reads them.
// Usage: node real-config.mjs OUTPUT_DIRECTORY   (run from the repository root)
import fs from 'node:fs';
import path from 'node:path';

const out = path.resolve(process.argv[2]);
const catalog = JSON.parse(fs.readFileSync('tools/xtensa-companions.json', 'utf8'));
const release = catalog.releases['23.1.3-1'];
const item = release.platforms['x86_64-linux'];
fs.writeFileSync(path.join(out, 'real.json'), JSON.stringify({
    version: '23.1.3-1', platform: 'x86_64-linux', llvmVersion: release.llvmVersion, sourceCommit: release.sourceCommit,
    sourceArchiveSha256: release.sourceArchiveSha256, archiveSha256: item.sha256, manifestSha256: item.manifestSha256,
}));
