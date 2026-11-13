// Small negative controls for the convergence gate, without compiler builds.
// Usage: node --test tools/test-bootstrap-convergence-unit.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test, { afterEach, beforeEach, describe } from 'node:test';
import * as gate from './test-bootstrap-convergence.mjs';

const names = ['stage2.ll', 'stage3.ll', 'stage2.bin', 'stage3.bin', 'stage2.o', 'stage3.o', 'environment.txt', 'closure.txt'];

function fixture() {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'convergence-unit-'));
    const dirs = [path.join(root, 'a'), path.join(root, 'b')];
    const manifests = [];
    for (const [which, directory] of [['a', dirs[0]], ['b', dirs[1]]]) {
        fs.mkdirSync(directory);
        const [version, checksum] = gate.SEEDS[which];
        for (const name of names) fs.writeFileSync(path.join(directory, name), name.endsWith('.ll') ? 'define i64 @main() { ret i64 42 }\n' : 'identical\n');
        const files = Object.fromEntries(names.map((name) => [name, gate.digest(path.join(directory, name))]));
        const stages = [...(which === 'b' ? ['historical-1', 'historical-2'] : []), 'stage1', 'stage2', 'stage3'];
        const builds = [];
        let previous = checksum;
        for (const name of stages) {
            const result = files[name + '.bin'] ?? name;
            builds.push({ name, source_revision: name.startsWith('historical-') ? gate.HISTORICAL : 'candidate', input_sha256: previous, output_sha256: result });
            previous = result;
        }
        manifests.push({
            schema: 1, route: which, status: 'passed', probe_exit: 42, candidate: { revision: 'candidate', tree: 'tree', archive_sha256: 'archive' },
            historical_revision: gate.HISTORICAL, historical_archive_sha256: 'historical', canonical_root: gate.CANONICAL_ROOT, entry: gate.ENTRY,
            representation: 'raw --emit-llvm, non-debug, pre-prune', settings: {}, seed: { version, sha256: checksum }, builds, files,
            toolchain: { environment_sha256: files['environment.txt'], closure_sha256: files['closure.txt'] },
        });
    }
    const writeManifests = () => dirs.forEach((directory, i) => gate.writeJson(path.join(directory, 'manifest.json'), manifests[i]));
    return { root, dirs, manifests, writeManifests, check() { writeManifests(); gate.compare(dirs[0], dirs[1], path.join(root, 'comparison')); } };
}

describe('comparison', () => {
    let f;
    beforeEach(() => { f = fixture(); });
    afterEach(() => fs.rmSync(f.root, { recursive: true, force: true }));

    test('shell output is not a toolchain closure root', () => {
        const env = 'llvm_tools=/nix/store/llvm/bin\nopenssl=/nix/store/ssl/lib\nldflags=-rpath /nix/store/not-realized-nix-shell/lib\n/nix/store/lld/bin/ld.lld\nLLD 23.1.3\n';
        assert.deepEqual(gate.toolchainStores(env), ['/nix/store/lld', '/nix/store/llvm', '/nix/store/ssl']);
    });
    test('identical complete routes', () => {
        f.check();
        assert.equal(JSON.parse(fs.readFileSync(path.join(f.root, 'comparison/comparison.json'), 'utf8')).passed, true);
    });
    test('no seed substitution', () => {
        f.manifests[1].seed = structuredClone(f.manifests[0].seed);
        assert.throws(() => f.check(), /wrong seed/);
    });
    test('missing historical stage', () => {
        f.manifests[1].builds.shift();
        assert.throws(() => f.check(), /missing bootstrap stage/);
    });
    test('broken chain', () => {
        f.manifests[1].builds[2].input_sha256 = 'published replacement';
        assert.throws(() => f.check(), /broken bootstrap chain/);
    });
    test('incomplete route', () => {
        f.manifests[1].status = 'incomplete';
        assert.throws(() => f.check(), /incomplete/);
    });
    test('different source', () => {
        f.manifests[1].candidate.archive_sha256 = 'different';
        assert.throws(() => f.check(), /provenance differs: candidate/);
    });
    test('the same stale revision on both routes', () => {
        f.writeManifests();
        assert.throws(() => gate.compare(f.dirs[0], f.dirs[1], path.join(f.root, 'comparison'), 'new dispatch'), /not the dispatched source/);
    });
    test('changed IR even with an updated manifest', () => {
        for (const stage of [2, 3]) {
            const name = `stage${stage}.ll`;
            fs.writeFileSync(path.join(f.dirs[1], name), '; abla.source="/different/root"\n');
            f.manifests[1].files[name] = gate.digest(path.join(f.dirs[1], name));
        }
        assert.throws(() => f.check(), /differs.*byte/);
    });
    test('corrupted artifact', () => {
        fs.writeFileSync(path.join(f.dirs[1], 'stage2.ll'), 'truncated');
        assert.throws(() => f.check(), /checksum mismatch/);
    });
    test('missing artifact', () => {
        fs.unlinkSync(path.join(f.dirs[1], 'stage3.o'));
        assert.throws(() => f.check(), { code: 'ENOENT' });
    });
    test('no fixed point', () => {
        const name = 'stage3.ll';
        fs.writeFileSync(path.join(f.dirs[1], name), 'not a fixed point');
        f.manifests[1].files[name] = gate.digest(path.join(f.dirs[1], name));
        assert.throws(() => f.check(), /differs.*byte/);
    });
    test('a failed comparison is recorded as failed', () => {
        f.manifests[1].status = 'incomplete';
        assert.throws(() => f.check());
        assert.equal(JSON.parse(fs.readFileSync(path.join(f.root, 'comparison/comparison.json'), 'utf8')).passed, false);
    });
});

describe('lineages: the pairs of routes the gate knows, selected by --lineage', () => {
    afterEach(() => gate.configure('v0.2.45'));

    test('the default is the first pair', () => {
        assert.equal(gate.HISTORICAL, 'ca9221b0615cd419284a9e8e9f671bf8429ccd3b');
        assert.equal(gate.SEEDS.a[0], 'v0.2.45');
        assert.equal(gate.SEEDS.b[0], 'v0.2.44');
    });
    test('every lineage is a distinct pinned pair', () => {
        for (const [name, lineage] of Object.entries(gate.LINEAGES)) {
            assert.match(lineage.historical, /^[0-9a-f]{40}$/, name);
            assert.deepEqual(Object.keys(lineage.seeds).sort(), ['a', 'b'], name);
            assert.equal(lineage.seeds.a[0], name, 'route A starts from the bridge tag\'s own release');
            assert.notEqual(lineage.seeds.a[0], lineage.seeds.b[0], name);
            for (const [version, checksum] of Object.values(lineage.seeds)) assert.match(checksum, /^[0-9a-f]{64}$/, version);
        }
    });
    test('configure selects and refuses', () => {
        gate.configure('v0.2.51');
        assert.equal(gate.SEEDS.a[0], 'v0.2.51');
        assert.equal(gate.SEEDS.b[0], 'v0.2.50');
        assert.equal(gate.HISTORICAL, '1758d94e64b0e7f31f22107f8556fd63dc4351c6');
        assert.throws(() => gate.configure('v9.9.9'), /unknown lineage/);
        assert.equal(gate.SEEDS.a[0], 'v0.2.51', 'a refused lineage leaves the selection alone');
    });
    test('lineages chain', () => {
        // Route B of a release is the previous release: its seed is the previous lineage's route A.
        assert.deepEqual(gate.LINEAGES['v0.2.52'].seeds.b, gate.LINEAGES['v0.2.51'].seeds.a);
        assert.deepEqual(gate.LINEAGES['v0.2.53'].seeds.b, gate.LINEAGES['v0.2.52'].seeds.a);
        assert.equal(gate.LINEAGES['v0.2.51'].seeds.b[0], 'v0.2.50');
        // v0.2.58: route B's seed is the release before it, which has no lineage of its own (v0.2.53 cannot build today's source).
        assert.equal(gate.LINEAGES['v0.2.58'].seeds.a[0], 'v0.2.58');
        assert.equal(gate.LINEAGES['v0.2.58'].seeds.b[0], 'v0.2.57');
    });
    test('the root defaults and is selectable', () => {
        assert.equal(gate.CANONICAL_ROOT, '/build/source');
        gate.configure('v0.2.45', '/scratch/build/source');
        assert.equal(gate.CANONICAL_ROOT, '/scratch/build/source');
        gate.configure('v0.2.45');
        assert.equal(gate.CANONICAL_ROOT, '/build/source', 'the next configure without a root restores the default');
    });
    test('routes of two roots are refused', () => {
        const f = fixture();
        try {
            f.writeManifests();
            gate.configure('v0.2.45', '/elsewhere/build/source');
            assert.throws(() => gate.compare(f.dirs[0], f.dirs[1], path.join(f.root, 'comparison')), /wrong IR contract/);
        } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
    });
    test('a route of another lineage is refused', () => {
        // A manifest built for the first pair must not pass the comparison of the newer one.
        const f = fixture();
        try {
            f.writeManifests();
            gate.configure('v0.2.51');
            assert.throws(() => gate.compare(f.dirs[0], f.dirs[1], path.join(f.root, 'comparison')), /wrong seed/);
        } finally { fs.rmSync(f.root, { recursive: true, force: true }); }
    });
});
