// Validate the native installation probe reports for all three hosts.
// Usage: node report-xtensa-install-probe.mjs ARTIFACTS OUTPUT
import fs from 'node:fs';
import path from 'node:path';

const [artifacts, output] = process.argv.slice(2);
const platforms = { 'ubuntu-24.04': 'x86_64-linux', 'macos-15': 'arm64-macos', 'macos-15-intel': 'x86_64-macos' };
const expected = {
    'patches.s': 'b860145a355d1b750c82c45903a8dfa5be685112dd444b9320ef0d109f5ce791',
    'patches.o': '528285e41bb3339affe60bf2cb324602bbed246fc147a5799be27c294150e4d1',
    'optimized.o': '8a12b98e9e44d332e9be540e5941a75b41dd3d9cf12068c20d251c72d4622672',
};
const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
const results = {}, errors = [];
for (const [runner, platform] of Object.entries(platforms)) {
    const file = path.join(artifacts, `xtensa-installed-${runner}-native`, 'result.json');
    try {
        const report = JSON.parse(fs.readFileSync(file, 'utf8'));
        if (report.installer !== 'native' || report.platform !== platform || report.status !== 'passed'
            || !report.statPreservedDsoTamperRejected || !report.nativePackageSha256 || !same(report.codegen, expected)) {
            throw new Error('missing or invalid success fields');
        }
        results[platform] = report;
    } catch (error) {
        errors.push(`${runner}: ${error.message}`);
    }
}
if (Object.keys(results).length === 3) {
    for (const key of ['parentVersion', 'version', 'unpublishedTestFixture']) {
        if (new Set(Object.values(results).map((report) => JSON.stringify(report[key] ?? null))).size !== 1) errors.push(`${key} differs across hosts`);
    }
}
const out = { status: errors.length ? 'failed' : 'passed', errors, platforms: results };
fs.mkdirSync(path.dirname(path.resolve(output)), { recursive: true });
fs.writeFileSync(output, JSON.stringify(out, null, 2) + '\n');
console.log(JSON.stringify(out, null, 2));
if (errors.length) process.exit(1);
