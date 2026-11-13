// The probe's report validator (tools/report-xtensa-install-probe.mjs) on matching, mismatched and missing legs, and
// that the probe's macOS setup in ci.yml is the release's.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../..');
const reporter = path.join(root, 'tools/report-xtensa-install-probe.mjs');
const release = fs.readFileSync(path.join(root, '.github/workflows/release.yml'), 'utf8');
const ci = fs.readFileSync(path.join(root, '.github/workflows/ci.yml'), 'utf8');
const releaseStart = release.indexOf('        run: |\n', release.indexOf('        name: Install the native toolchain'));
const releaseEnd = release.indexOf('      - name: Prepare the bootstrap compiler', releaseStart);
const probeStart = ci.indexOf('        run: |\n', ci.indexOf('      - name: Install native build dependencies on macOS'));
const probeEnd = ci.indexOf('      - name: Install native build dependencies on Linux', probeStart);
assert.ok(releaseStart >= 0 && releaseEnd > releaseStart && probeStart >= 0 && probeEnd > probeStart);
const releaseSetup = release.slice(releaseStart, releaseEnd)
    .replace("'${{ matrix.architecture }}' == x86_64", "'${{ matrix.platform }}' == x86_64-macos");
const probeSetup = ci.slice(probeStart, probeEnd);
assert.equal(probeSetup, releaseSetup, 'probe macOS setup differs from release setup');
assert.notEqual(probeSetup.replaceAll('23.1.0', '23.1.5'), releaseSetup);
const shell = probeSetup.split('\n').slice(1).map((line) => line.slice(10)).join('\n') + '\n';
assert.equal(spawnSync('bash', ['-n'], { input: shell, encoding: 'utf8' }).status, 0);

const base = fs.mkdtempSync(path.join(os.tmpdir(), 'xtensa-probe-report-'));
try {
    const artifacts = path.join(base, 'artifacts');
    const codegen = {
        'patches.s': 'b860145a355d1b750c82c45903a8dfa5be685112dd444b9320ef0d109f5ce791',
        'patches.o': '528285e41bb3339affe60bf2cb324602bbed246fc147a5799be27c294150e4d1',
        'optimized.o': '8a12b98e9e44d332e9be540e5941a75b41dd3d9cf12068c20d251c72d4622672',
    };
    for (const [runner, platform] of [['ubuntu-24.04', 'x86_64-linux'], ['macos-15', 'arm64-macos'], ['macos-15-intel', 'x86_64-macos']]) {
        const directory = path.join(artifacts, `xtensa-installed-${runner}-native`);
        fs.mkdirSync(directory, { recursive: true });
        fs.writeFileSync(path.join(directory, 'result.json'), JSON.stringify({
            installer: 'native', platform, status: 'passed', parentVersion: 'v0.2.48', version: '23.1.3-1', codegen,
            unpublishedTestFixture: false, statPreservedDsoTamperRejected: true, nativePackageSha256: 'pin' }));
    }
    const output = path.join(base, 'comparison.json');
    const report = () => spawnSync(process.execPath, [reporter, artifacts, output], { stdio: ['ignore', 'ignore', 'inherit'] }).status;
    assert.equal(report(), 0);
    const file = path.join(artifacts, 'xtensa-installed-ubuntu-24.04-native/result.json');
    const record = JSON.parse(fs.readFileSync(file, 'utf8'));
    record.codegen['patches.o'] = 'wrong';
    fs.writeFileSync(file, JSON.stringify(record));
    assert.notEqual(report(), 0);
    assert.equal(JSON.parse(fs.readFileSync(output, 'utf8')).status, 'failed');
    fs.unlinkSync(file);
    assert.notEqual(report(), 0);
} finally {
    fs.rmSync(base, { recursive: true, force: true });
}
console.log('xtensa probe report: matching, mismatched and missing legs checked');
