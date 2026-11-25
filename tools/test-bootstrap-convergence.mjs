// Manual Linux historical-seed convergence; never publishes or replaces a seed.
//
//   node tools/test-bootstrap-convergence.mjs route [--lineage L] [--root DIR] [--wrap CMD] (a|b) OUTPUT
//   node tools/test-bootstrap-convergence.mjs compare [--lineage L] [--root DIR] A B OUTPUT
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const SELF = path.join(HERE, '..');

export const HISTORICAL_DEFAULT = 'ca9221b0615cd419284a9e8e9f671bf8429ccd3b'; // v0.2.45
export let HISTORICAL = HISTORICAL_DEFAULT;
const SEEDS_DEFAULT = {
    a: ['v0.2.45', 'f30c9027a23923bcb97bb27d1b23f818e612e7aed157636d72db136aa56006f3'],
    b: ['v0.2.44', '90a5614b3557221baf62a224160d4b42e884bcd18545af8475da22c096f03a98'],
};
export let SEEDS = { ...SEEDS_DEFAULT };
export let LINEAGE = 'v0.2.45'; // the name configure() selected
// The pairs of routes the gate knows. A lineage names the tag whose source route B rebuilds (the "bridge"), the route A
// seed (that tag's own release) and the route B seed (the release before it). The default is the first pair the gate
// was built for; --lineage picks a newer one. Seeds are checksum-pinned release assets.
// Where the candidate source sits; CI reserves this path, a local run names its own (configure(lineage, root)).
export let CANONICAL_ROOT = '/build/source';
export const LINEAGES = {
    'v0.2.45': { historical: HISTORICAL_DEFAULT, seeds: { ...SEEDS_DEFAULT } },
    'v0.2.51': {
        historical: '1758d94e64b0e7f31f22107f8556fd63dc4351c6',
        seeds: {
            a: ['v0.2.51', 'd8e24762f3657cfc90289a6bc93ddcb6aa7b9df8338c93d4090e5b06319f4d7d'],
            b: ['v0.2.50', 'aa40e582e66f40013571b7ef1311e9079582d0fbeffa7843d57707a18205b7a9'],
        },
    },
    'v0.2.52': {
        historical: '0eaf983ef383d773896cb1e258918ca5b9304bbb',
        seeds: {
            a: ['v0.2.52', '126d8355386c9a4b5e46ab9d14d99ebab66ed6dcb2c84832a94b58fcd6ceefb3'],
            b: ['v0.2.51', 'd8e24762f3657cfc90289a6bc93ddcb6aa7b9df8338c93d4090e5b06319f4d7d'],
        },
    },
    'v0.2.53': {
        historical: 'b9ed669ce148440cef09650dde9db4085358f0cd',
        seeds: {
            a: ['v0.2.53', '49e1141c4b7d5782ecc46a0cefde11e831e453af30cd74f808c1dcca2c09e341'],
            b: ['v0.2.52', '126d8355386c9a4b5e46ab9d14d99ebab66ed6dcb2c84832a94b58fcd6ceefb3'],
        },
    },
    // The first lineage today's source can build: v0.2.53 cannot (the intrinsic ablaHostOwnsRuntime arrived in v0.2.57), so route A
    // starts from the v0.2.58 release and route B from v0.2.57, which rebuilds v0.2.58's source (the tag's commit) first.
    'v0.2.58': {
        historical: '6663f29084c0b2f6b90255b2aa12a7ec84ce5a55',
        seeds: {
            a: ['v0.2.58', '3de95d4e46fc43010319cfe619104e683d304e0ffcfb4239b8618de891c4e09e'],
            b: ['v0.2.57', '8f7fad343a2171d694d6632c5268e7b3e2c8d5b4d916d2da1381cbf332fd1278'],
        },
    },
    // Each later release adds its entry (docs/bootstrap.md, "Release step"); the historical revision is the tag's commit.
    'v0.2.59': {
        historical: 'c917ba5701d3deae68ac1284cc0476a6de5b0b5c',
        seeds: {
            a: ['v0.2.59', 'd3a3457ff6def72a85844ba9a6cc384a321582e7a3349a4f8447abe62768f700'],
            b: ['v0.2.58', '3de95d4e46fc43010319cfe619104e683d304e0ffcfb4239b8618de891c4e09e'],
        },
    },
    'v0.2.60': {
        historical: '3c3d714b5163a05627ecccf2e95871f041392d05',
        seeds: {
            a: ['v0.2.60', '1d6b1d1985caeb0dfc45ba0c0d35de843168d5ea18781bf22814d436a21c60db'],
            b: ['v0.2.59', 'd3a3457ff6def72a85844ba9a6cc384a321582e7a3349a4f8447abe62768f700'],
        },
    },
    'v0.2.61': {
        historical: '8bdb252198448058d33e2e337de6f039b068ddc1',
        seeds: {
            a: ['v0.2.61', '5c307e3d313d5367510ea84fabdc1eb49df5eb79d2e25dbd554c87ebd846409d'],
            b: ['v0.2.60', '1d6b1d1985caeb0dfc45ba0c0d35de843168d5ea18781bf22814d436a21c60db'],
        },
    },
    'v0.2.62': {
        historical: '26ae8b23a4e9220c7a00f02aa12c3a031de344b8',
        seeds: {
            a: ['v0.2.62', 'f227678a03588138a1770f054edd9f88f54cb64fcaf1776c60672bfbf52903af'],
            b: ['v0.2.61', '5c307e3d313d5367510ea84fabdc1eb49df5eb79d2e25dbd554c87ebd846409d'],
        },
    },
    'v0.2.63': {
        historical: '8945fd39de30b0b4692a555d9fe3c00bf0f7d715',
        seeds: {
            a: ['v0.2.63', 'b63fdd0eaeb5451b399ea4f0c38199fc27a40791ce6f93423923363e21e30518'],
            b: ['v0.2.62', 'f227678a03588138a1770f054edd9f88f54cb64fcaf1776c60672bfbf52903af'],
        },
    },
    'v0.2.64': {
        historical: '2611d70a069bde85265910511dbcd21501c48eef',
        seeds: {
            a: ['v0.2.64', '708d1cc5d50b318fb763113d16977ee209c9c6c5b39d1afdf96a43824c74be92'],
            b: ['v0.2.63', 'b63fdd0eaeb5451b399ea4f0c38199fc27a40791ce6f93423923363e21e30518'],
        },
    },
    'v0.2.65': {
        historical: 'ed00a14c893a72671d4a2ec24140231ffd8544f8',
        seeds: {
            a: ['v0.2.65', 'b5ee36b5a4a535cf6a7696ae9a1f17a544e9e02b468f1e79be4f2ea5cd90c3c9'],
            b: ['v0.2.64', '708d1cc5d50b318fb763113d16977ee209c9c6c5b39d1afdf96a43824c74be92'],
        },
    },
    'v0.2.66': {
        historical: 'fba51e1e7883f3e4169b0c6cd5f03c320c227bb3',
        seeds: {
            a: ['v0.2.66', '1cc6b9f94dfcfed1c72f33c3e826c25f7bf251361308d11b9097b0cac9c7d8f6'],
            b: ['v0.2.65', 'b5ee36b5a4a535cf6a7696ae9a1f17a544e9e02b468f1e79be4f2ea5cd90c3c9'],
        },
    },
    'v0.2.67': {
        historical: '36634a91818ab18a1173ef3ccfd1db0feef4fff1',
        seeds: {
            a: ['v0.2.67', '1ad0c494de77596139c052b778bbafc3bfed329b801ef90a75b0a7f64808bc27'],
            b: ['v0.2.66', '1cc6b9f94dfcfed1c72f33c3e826c25f7bf251361308d11b9097b0cac9c7d8f6'],
        },
    },
    'v0.2.68': {
        historical: 'f9ec0852bfe3690a042ee9c95dfd00f5dbeab1d5',
        seeds: {
            a: ['v0.2.68', '4f7dee2c7a16826705aa32e7ba5466b599cc1432274190007e4ea582883a3a09'],
            b: ['v0.2.67', '1ad0c494de77596139c052b778bbafc3bfed329b801ef90a75b0a7f64808bc27'],
        },
    },
    'v0.2.69': {
        historical: '150c711dffa00a28993196e4f3d24bc45525878a',
        seeds: {
            a: ['v0.2.69', 'eeddb7c09e282df4b9b7c79714dac68d2ebb21f9a4e7e90c1211f110c7be8f61'],
            b: ['v0.2.68', '4f7dee2c7a16826705aa32e7ba5466b599cc1432274190007e4ea582883a3a09'],
        },
    },
    'v0.2.70': {
        historical: '93841eec824233d18cfa987bd1bb7d430deac016',
        seeds: {
            a: ['v0.2.70', 'a6d6fb279ab6cf8a93703e36d6d5fbece49229fc416cb8a2c4a5b75504a96ad4'],
            b: ['v0.2.69', 'eeddb7c09e282df4b9b7c79714dac68d2ebb21f9a4e7e90c1211f110c7be8f61'],
        },
    },
    'v0.2.71': {
        historical: '4f73994cff344c5d11500ab416ac8512232b2548',
        seeds: {
            a: ['v0.2.71', 'e80eed4c65c9ea87f0cb4aef196e581dde1649407a3f1e6ccd849b577c38a69e'],
            b: ['v0.2.70', 'a6d6fb279ab6cf8a93703e36d6d5fbece49229fc416cb8a2c4a5b75504a96ad4'],
        },
    },
    'v0.2.72': {
        historical: '0d3c4b0903cf7f21966c23d5ba60fc0c622a013d',
        seeds: {
            a: ['v0.2.72', 'a4f9c843f6cf4d00c914ff321d4abca1d82cff90d21f20839e9d50ad54c3f929'],
            b: ['v0.2.71', 'e80eed4c65c9ea87f0cb4aef196e581dde1649407a3f1e6ccd849b577c38a69e'],
        },
    },
    'v0.2.73': {
        historical: '23156facdb6fdab28c5b230290fa9758be8578fa',
        seeds: {
            a: ['v0.2.73', '8a67ba0cf4e28af968e1b36899c87db2b77c48249674b017cfa7cda620dd23e2'],
            b: ['v0.2.72', 'a4f9c843f6cf4d00c914ff321d4abca1d82cff90d21f20839e9d50ad54c3f929'],
        },
    },
    'v0.2.74': {
        historical: 'e69fba5065dcf67b2c2758cc5ae8137c807898cb',
        seeds: {
            a: ['v0.2.74', '03337bf89f919b8506497894ecf20723a8e04e9f3a4f86a42a9e3d9ac7bc7471'],
            b: ['v0.2.73', '8a67ba0cf4e28af968e1b36899c87db2b77c48249674b017cfa7cda620dd23e2'],
        },
    },
};

/** Select the pair of routes (the module-level HISTORICAL and SEEDS the rest of the gate reads), and where the candidate
 *  source sits. Both routes and the comparison must use the same root: the IR carries source paths. CI reserves
 *  /build/source; a local run without it names a directory it owns, such as <scratch>/build/source. */
export function configure(lineage, root = null) {
    if (!(lineage in LINEAGES)) throw new Error(`unknown lineage ${lineage}; known: ${Object.keys(LINEAGES).sort().join(', ')}`);
    LINEAGE = lineage;
    HISTORICAL = LINEAGES[lineage].historical;
    SEEDS = { a: [...LINEAGES[lineage].seeds.a], b: [...LINEAGES[lineage].seeds.b] };
    CANONICAL_ROOT = root ?? '/build/source';
}

// A command put in front of every build step (a shared machine's queue); empty in CI.
export const WRAPPER = [];
export const ENTRY = 'src/orc_main.ab';

export function digest(file) {
    const hash = createHash('sha256');
    const descriptor = fs.openSync(file, 'r');
    const chunk = Buffer.alloc(1024 * 1024);
    try {
        for (let n; (n = fs.readSync(descriptor, chunk, 0, chunk.length, null)) > 0;) hash.update(chunk.subarray(0, n));
    } finally { fs.closeSync(descriptor); }
    return hash.digest('hex');
}

const sortKeys = (x) => (Array.isArray(x) ? x.map(sortKeys) : x !== null && typeof x === 'object'
    ? Object.fromEntries(Object.keys(x).sort().map((k) => [k, sortKeys(x[k])])) : x);
export const writeJson = (file, value) => fs.writeFileSync(file, JSON.stringify(sortKeys(value), null, 2) + '\n');
const readJson = (file) => JSON.parse(fs.readFileSync(file, 'utf8'));

export function toolchainStores(environment) {
    // mkShell puts its unrealized `out` in NIX_LDFLAGS. Keep that text in the provenance, but query closures of actual
    // tool/crypto roots, not shell out.
    const stores = new Set();
    for (const line of environment.split('\n')) {
        const value = line.startsWith('llvm_tools=') || line.startsWith('openssl=') ? line.slice(line.indexOf('=') + 1) : line;
        if (value.startsWith('/nix/store/')) stores.add(value.split('/').slice(0, 4).join('/'));
    }
    if (stores.size === 0) throw new Error('missing pinned Nix toolchain paths');
    return [...stores].sort();
}

/** Exact comparison, with a bounded first-difference diagnostic. */
export function same(left, right) {
    const a = fs.openSync(left, 'r'), b = fs.openSync(right, 'r');
    try {
        let offset = 0;
        const x = Buffer.alloc(65536), y = Buffer.alloc(65536);
        for (;;) {
            const nx = fs.readSync(a, x, 0, x.length, null), ny = fs.readSync(b, y, 0, y.length, null);
            const cx = x.subarray(0, nx), cy = y.subarray(0, ny);
            if (!cx.equals(cy)) {
                let at = 0;
                while (at < Math.min(nx, ny) && cx[at] === cy[at]) at++;
                const show = (c) => JSON.stringify(c.subarray(Math.max(0, at - 40), at + 80).toString('latin1'));
                throw new Error(`${left} differs from ${right} at byte ${offset + at}: ${show(cx)} / ${show(cy)}`);
            }
            if (nx === 0) return;
            offset += nx;
        }
    } finally { fs.closeSync(a); fs.closeSync(b); }
}

// Python's shlex.quote / shlex.join.
const quote = (s) => (/^[A-Za-z0-9_@%+=:,./-]+$/.test(s) ? s : s === '' ? "''" : "'" + s.replaceAll("'", "'\"'\"'") + "'");
const join = (args) => args.map((a) => quote(String(a))).join(' ');

function command(argv, cwd, log, env = undefined, output = null, timeout = 1800) {
    if (WRAPPER.length) timeout = null; // the wrapper may queue for a slot; its time is not the build's
    console.log('+', join(argv));
    const errors = fs.openSync(log, 'w');
    const result = output === null ? null : fs.openSync(output, 'w');
    try {
        const r = spawnSync(argv[0], argv.slice(1).map(String), {
            cwd, env, stdio: ['inherit', result ?? errors, errors], timeout: timeout === null ? undefined : timeout * 1000,
        });
        if (r.status !== 0) throw new Error(`${join(argv)}: exit ${r.status ?? r.signal}`);
    } finally {
        fs.closeSync(errors);
        if (result !== null) fs.closeSync(result);
    }
}

const git = (args, cwd) => {
    const r = spawnSync('git', args, { cwd, encoding: 'utf8' });
    if (r.status !== 0) throw new Error(`git ${args.join(' ')}: ${r.stderr}`);
    return r.stdout.trim();
};

function archive(repo, revision, file) {
    const stream = fs.openSync(file, 'w');
    try {
        const r = spawnSync('git', ['archive', '--format=tar', revision], { cwd: repo, stdio: ['ignore', stream, 'inherit'] });
        if (r.status !== 0) throw new Error('git archive failed');
    } finally { fs.closeSync(stream); }
    return digest(file);
}

const affinity = () => {
    const text = spawnSync('taskset', ['-cp', String(process.pid)], { encoding: 'utf8' }).stdout.trim().split(':').pop().trim();
    return text.split(',').flatMap((part) => {
        const [x, y] = part.trim().split('-').map(Number);
        return Array.from({ length: (y ?? x) - x + 1 }, (_, i) => x + i);
    }).sort((p, q) => p - q);
};

function route(which, repo, output) {
    if (process.platform !== 'linux') throw new Error('Linux only');
    const root = CANONICAL_ROOT;
    const historical = path.join(path.dirname(root), 'historical');
    // Never clean an existing checkout, even when it belongs to the caller.
    if (fs.existsSync(root) || fs.existsSync(historical)) throw new Error(`requires fresh ${root} and ${historical}; refusing to replace either`);
    fs.mkdirSync(path.dirname(output), { recursive: true }); // parents, like the Python mkdir(parents=True)
    fs.mkdirSync(output); // not recursive-existing: a leftover output is an error
    const revision = git(['rev-parse', 'HEAD'], repo);
    const tree = git(['rev-parse', 'HEAD^{tree}'], repo);
    const [version, checksum] = SEEDS[which];
    const manifest = {
        schema: 1, route: which, status: 'incomplete', candidate: { revision, tree }, historical_revision: HISTORICAL,
        canonical_root: CANONICAL_ROOT, entry: ENTRY, representation: 'raw --emit-llvm, non-debug, pre-prune',
        seed: { version, sha256: checksum }, builds: [], files: {},
    };
    writeJson(path.join(output, 'manifest.json'), manifest);
    const sourceTar = path.join(output, 'source.tar'), historyTar = path.join(output, 'historical.tar');
    const parent = path.dirname(root);
    try {
        manifest.candidate.archive_sha256 = archive(repo, revision, sourceTar);
        manifest.historical_archive_sha256 = archive(repo, HISTORICAL, historyTar);
        for (const [tar, destination] of [[sourceTar, root], [historyTar, historical]]) {
            fs.mkdirSync(destination, { recursive: true });
            if (spawnSync('tar', ['-xf', tar, '-C', destination]).status !== 0) throw new Error('tar failed');
        }
        fs.unlinkSync(sourceTar);
        fs.unlinkSync(historyTar);
        for (const name of ['home', 'tmp', 'cache', 'bootstrap']) fs.mkdirSync(path.join(parent, name));
        const cpus = affinity().slice(0, 4);
        // --pure removes ambient ABLA_*, LD_*, grants and optimization overrides.
        const env = { ...process.env, HOME: path.join(parent, 'home'), TMPDIR: path.join(parent, 'tmp') };
        const shellSettings = {
            CI: 'true', TZ: 'UTC', LC_ALL: 'C', JOBS: String(cpus.length), ABLA_NATIVE_JOBS: String(cpus.length), ABLA_CODEGEN_JOBS: String(cpus.length),
            ABLA_CACHE_DIR: path.join(parent, 'cache'), ABLA_MAX_MEMORY_MB: '4096', ABLA_MAX_STACK_KB: '131072', ABLA_RELEASE_SELFHOST_BUILD_SECONDS: '1800',
        };
        manifest.settings = Object.fromEntries(Object.entries(shellSettings).filter(([k]) => !['JOBS', 'ABLA_NATIVE_JOBS', 'ABLA_CODEGEN_JOBS'].includes(k)));
        manifest.cpus = cpus;

        const shell = (source, args, label, stdout = null) => {
            const settings = { ...shellSettings, ABLA_SYSROOT: String(source) };
            const body = 'ulimit -s 131072; exec env ' + join([...Object.entries(settings).map(([k, v]) => `${k}=${v}`), ...args]);
            command([...WRAPPER, 'taskset', '-c', cpus.join(','), 'nix-shell', '--pure', path.join(source, 'shell.nix'), '--arg', 'xtensa', 'true', '--run', body],
                source, path.join(output, label + '.log'), env, stdout);
        };

        // Capture the immutable tool paths, versions and their full Nix closures.
        shell(root, ['bash', '-c', 'printf "llvm_tools=%s\\nopenssl=%s\\nldflags=%s\\n" "$ABLA_LLVM_TOOLS" "$ABLA_LINUX_OPENSSL_LIB" "$NIX_LDFLAGS"; for tool in opt llc ld.lld clang; do command -v "$tool"; "$tool" --version | sed -n "1,2p"; done'],
            'environment', path.join(output, 'environment.txt'));
        const environment = fs.readFileSync(path.join(output, 'environment.txt'), 'utf8');
        const closureResult = spawnSync('nix-store', ['--query', '--requisites', ...toolchainStores(environment)], { encoding: 'utf8' });
        if (closureResult.status !== 0) throw new Error('nix-store --query failed');
        fs.writeFileSync(path.join(output, 'closure.txt'), [...new Set(closureResult.stdout.split('\n').filter(Boolean))].sort().join('\n') + '\n');
        manifest.toolchain = { environment_sha256: digest(path.join(output, 'environment.txt')), closure_sha256: digest(path.join(output, 'closure.txt')) };
        const seed = path.join(parent, 'bootstrap', 'seed.bin');
        const url = `https://github.com/AndreBaltazar8/ablac/releases/download/${version}/ablac-x86_64-linux`;
        command(['curl', '--fail', '--location', '--retry', '3', '--output', seed, url], repo, path.join(output, 'seed-download.log'), env);
        if (digest(seed) !== checksum) throw new Error('seed checksum mismatch; no fallback');
        fs.chmodSync(seed, 0o755);

        const build = (source, compiler, binary, label) => {
            const started = process.hrtime.bigint();
            const before = digest(compiler);
            shell(source, [path.join(source, 'tools/build-self-hosted-current.sh'), compiler, binary, ENTRY], label);
            manifest.builds.push({
                name: label, source_revision: source === historical ? HISTORICAL : revision, input_sha256: before, output_sha256: digest(binary),
                seconds: Math.round(Number(process.hrtime.bigint() - started) / 1e6) / 1000,
            });
            writeJson(path.join(output, 'manifest.json'), manifest);
            return binary;
        };

        let compiler = seed;
        if (which === 'b') {
            for (const stage of [1, 2]) compiler = build(historical, compiler, path.join(parent, 'bootstrap', `historical-${stage}.bin`), `historical-${stage}`);
        }
        for (const stage of [1, 2, 3]) compiler = build(root, compiler, path.join(root, 'build', `stage${stage}.bin`), `stage${stage}`);
        for (const stage of [2, 3]) {
            const binary = path.join(root, 'build', `stage${stage}.bin`);
            shell(root, [binary, '--emit-llvm', ENTRY], `emit-stage${stage}`, path.join(output, `stage${stage}.ll`));
            shell(root, ['opt', '-passes=verify', '-disable-output', path.join(output, `stage${stage}.ll`)], `verify-stage${stage}`);
            // Move only after all generations have finished using these outputs.
            for (const [from, name] of [[binary, `stage${stage}.bin`], [binary + '.o', `stage${stage}.o`]]) fs.renameSync(from, path.join(output, name));
        }
        for (const suffix of ['ll', 'bin', 'o']) same(path.join(output, `stage2.${suffix}`), path.join(output, `stage3.${suffix}`));
        const probe = path.join(root, 'build', 'convergence-probe.ab');
        fs.writeFileSync(probe, 'fun main: int = 42\n');
        const probeBinary = probe.slice(0, -'.ab'.length);
        shell(root, [path.join(output, 'stage3.bin'), 'build', probe, '-o', probeBinary, '--fast', '--no-cache'], 'probe-build');
        const result = spawnSync(probeBinary, { cwd: root, env, timeout: 30000 });
        if (result.status !== 42) throw new Error(`native child exited ${result.status}, expected42`);
        manifest.probe_exit = result.status;
        for (const name of ['stage2.ll', 'stage3.ll', 'stage2.bin', 'stage3.bin', 'stage2.o', 'stage3.o', 'environment.txt', 'closure.txt']) {
            manifest.files[name] = digest(path.join(output, name));
        }
        manifest.status = 'passed';
    } catch (error) {
        manifest.error = error.message;
        throw error;
    } finally {
        writeJson(path.join(output, 'manifest.json'), manifest);
    }
}

const jsonEqual = (x, y) => JSON.stringify(sortKeys(x)) === JSON.stringify(sortKeys(y));

export function compare(a, b, output, expectedRevision = null) {
    fs.mkdirSync(path.dirname(output), { recursive: true });
    fs.mkdirSync(output); // not recursive-existing
    try {
        const manifests = [];
        for (const [which, directory] of [['a', a], ['b', b]]) {
            const m = readJson(path.join(directory, 'manifest.json'));
            if (m.schema !== 1 || m.route !== which || m.status !== 'passed' || m.probe_exit !== 42) throw new Error(`route ${which}: incomplete or wrong provenance`);
            const [version, checksum] = SEEDS[which];
            if (!jsonEqual(m.seed, { version, sha256: checksum }) || m.historical_revision !== HISTORICAL) throw new Error(`route ${which}: wrong seed or bridge`);
            if (m.canonical_root !== CANONICAL_ROOT || m.entry !== ENTRY || m.representation !== 'raw --emit-llvm, non-debug, pre-prune') throw new Error(`route ${which}: wrong IR contract`);
            if (expectedRevision !== null && m.candidate.revision !== expectedRevision) throw new Error(`route ${which}: not the dispatched source revision`);
            const expected = [...(which === 'b' ? ['historical-1', 'historical-2'] : []), 'stage1', 'stage2', 'stage3'];
            if (!jsonEqual(m.builds.map((s) => s.name), expected)) throw new Error(`route ${which}: missing bootstrap stage`);
            let previous = checksum;
            for (const stage of m.builds) {
                const source = stage.name.startsWith('historical-') ? HISTORICAL : m.candidate.revision;
                if (stage.input_sha256 !== previous || stage.source_revision !== source) throw new Error(`route ${which}: broken bootstrap chain`);
                previous = stage.output_sha256;
            }
            const names = ['stage2.ll', 'stage3.ll', 'stage2.bin', 'stage3.bin', 'stage2.o', 'stage3.o', 'environment.txt', 'closure.txt'];
            for (const name of names) {
                if (digest(path.join(directory, name)) !== m.files[name]) throw new Error(`route ${which}: artifact checksum mismatch: ${name}`);
            }
            if (!jsonEqual(m.toolchain, { environment_sha256: m.files['environment.txt'], closure_sha256: m.files['closure.txt'] })) throw new Error(`route ${which}: inconsistent toolchain provenance`);
            for (const stage of [2, 3]) {
                const record = m.builds.find((s) => s.name === `stage${stage}`);
                if (record.output_sha256 !== m.files[`stage${stage}.bin`]) throw new Error(`route ${which}: compiler artifact not produced by recorded stage`);
            }
            for (const suffix of ['ll', 'bin', 'o']) same(path.join(directory, `stage2.${suffix}`), path.join(directory, `stage3.${suffix}`));
            manifests.push(m);
        }
        for (const key of ['candidate', 'historical_archive_sha256', 'canonical_root', 'entry', 'representation', 'settings', 'toolchain']) {
            if (!jsonEqual(manifests[0][key], manifests[1][key])) throw new Error(`route provenance differs: ${key}`);
        }
        for (const name of ['environment.txt', 'closure.txt', 'stage2.ll', 'stage2.bin', 'stage2.o']) same(path.join(a, name), path.join(b, name));
        writeJson(path.join(output, 'comparison.json'), {
            passed: true, candidate: manifests[0].candidate, canonical_ir_sha256: manifests[0].files['stage2.ll'],
            // The seed manifest: what both routes started from, for the release notes (tools/release-convergence.sh).
            lineage: LINEAGE, seeds: { a: { version: SEEDS.a[0], sha256: SEEDS.a[1] }, b: { version: SEEDS.b[0], sha256: SEEDS.b[1] } },
            historical_revision: HISTORICAL, canonical_root: CANONICAL_ROOT, entry: ENTRY, settings: manifests[0].settings,
            toolchain: manifests[0].toolchain, stage2_binary_sha256: manifests[0].files['stage2.bin'],
            stage2_object_sha256: manifests[0].files['stage2.o'],
            claim: 'historical-seed route convergence; not independent implementation',
        });
    } catch (error) {
        writeJson(path.join(output, 'comparison.json'), { passed: false, error: error.message });
        throw error;
    }
}

function main(argv) {
    const [mode, ...rest] = argv;
    if (mode !== 'route' && mode !== 'compare') { console.error('usage: test-bootstrap-convergence.mjs route|compare ...'); process.exit(2); }
    const options = { lineage: 'v0.2.58', root: null, wrap: '' };
    const positional = [];
    for (let i = 0; i < rest.length; i++) {
        if (rest[i] === '--lineage' || rest[i] === '--root' || rest[i] === '--wrap') options[rest[i].slice(2)] = rest[++i];
        else positional.push(rest[i]);
    }
    if (!(options.lineage in LINEAGES)) { console.error(`invalid --lineage ${options.lineage}; known: ${Object.keys(LINEAGES).sort().join(', ')}`); process.exit(2); }
    if (options.root !== null && !path.isAbsolute(options.root)) { console.error('--root must be an absolute path'); process.exit(2); }
    configure(options.lineage, options.root);
    if (mode === 'route') {
        if (!['a', 'b'].includes(positional[0]) || positional.length !== 2) { console.error('route needs (a|b) OUTPUT'); process.exit(2); }
        WRAPPER.push(...(options.wrap.match(/(?:[^\s'"]+|'[^']*'|"[^"]*")+/g) ?? []).map((w) => w.replace(/^(['"])(.*)\1$/, '$2')));
        route(positional[0], SELF, path.resolve(positional[1]));
    } else {
        if (positional.length !== 3) { console.error('compare needs A B OUTPUT'); process.exit(2); }
        compare(path.resolve(positional[0]), path.resolve(positional[1]), path.resolve(positional[2]), git(['rev-parse', 'HEAD'], SELF));
    }
}

if (process.argv[1] && import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href) {
    try { main(process.argv.slice(2)); } catch (error) { console.error(error.message); process.exit(1); }
}
