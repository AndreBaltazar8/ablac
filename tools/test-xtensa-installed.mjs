// Opt-in real published-toolchain installation probe; no LLVM source builds.
// Usage: node test-xtensa-installed.mjs OUTPUT --native-package CANDIDATE.tar.gz [--unpublished-fixture FIXTURE.json --archive ARCHIVE.tar.gz]
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const CATALOG = path.join(here, 'xtensa-companions.json');
const HOSTS = { 'linux/x64': 'x86_64-linux', 'darwin/arm64': 'arm64-macos', 'darwin/x64': 'x86_64-macos' };

const fail = (message) => { throw new Error(message); };
const hostPlatform = () => HOSTS[`${process.platform}/${process.arch}`] ?? fail('unsupported probe host');
const fileSha256 = (file) => {
    const hash = createHash('sha256');
    const descriptor = fs.openSync(file, 'r');
    const chunk = Buffer.alloc(1024 * 1024);
    try {
        for (let n; (n = fs.readSync(descriptor, chunk, 0, chunk.length, null)) > 0;) hash.update(chunk.subarray(0, n));
    } finally { fs.closeSync(descriptor); }
    return hash.digest('hex');
};
// The native installer and native catalog checker validate the schema and pins.
const loadCatalog = (file = CATALOG) => JSON.parse(fs.readFileSync(file, 'utf8'));

async function download(url, destination, expected) {
    const response = await fetch(url, { signal: AbortSignal.timeout(600000) });
    if (!response.ok) fail(`download ${url}: ${response.status}`);
    const digest = createHash('sha256');
    let total = 0;
    const out = fs.openSync(destination, 'w');
    try {
        for await (const chunk of response.body) {
            total += chunk.length;
            if (total > 512 * 1024 * 1024) fail('probe parent archive exceeds limit');
            digest.update(chunk);
            fs.writeSync(out, chunk);
        }
    } finally { fs.closeSync(out); }
    if (digest.digest('hex') !== expected) fail('probe parent archive SHA-256 mismatch');
}

function run(...args) {
    args = args.map(String);
    console.log('+', ...args);
    const result = spawnSync(args[0], args.slice(1), { stdio: 'inherit', timeout: 120000 });
    if (result.status !== 0) fail(`${args.join(' ')}: exit ${result.status ?? result.signal}`);
}

function snapshot(root) {
    const result = {};
    const walk = (directory) => {
        for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
            const target = path.join(directory, entry.name);
            const name = path.relative(root, target);
            if (entry.isSymbolicLink()) result[name] = ['link', fs.readlinkSync(target)];
            else if (entry.isFile()) result[name] = ['file', fileSha256(target), fs.statSync(target).mode];
            else if (entry.isDirectory()) walk(target);
        }
    };
    walk(root);
    return result;
}

function parseArguments(argv) {
    const options = { output: null, unpublishedFixture: null, archive: null, nativePackage: null };
    for (let i = 0; i < argv.length; i++) {
        const arg = argv[i];
        if (arg === '--unpublished-fixture') options.unpublishedFixture = argv[++i];
        else if (arg === '--archive') options.archive = argv[++i];
        else if (arg === '--native-package') options.nativePackage = argv[++i];
        else if (!arg.startsWith('--') && options.output === null) options.output = arg;
        else { console.error(`unknown argument ${arg}`); process.exit(2); }
    }
    if (!options.output || !options.nativePackage) { console.error('usage: test-xtensa-installed.mjs OUTPUT --native-package PATH [--unpublished-fixture F --archive A]'); process.exit(2); }
    if (Boolean(options.unpublishedFixture) !== Boolean(options.archive)) { console.error('--unpublished-fixture and --archive must be used together'); process.exit(2); }
    return options;
}

async function main() {
    const args = parseArguments(process.argv.slice(2));
    const output = path.resolve(args.output);
    fs.mkdirSync(path.dirname(output), { recursive: true }); // parents, like the Python mkdir(parents=True)
    fs.mkdirSync(output); // not recursive-existing: a leftover output directory is an error
    let catalogArgs = [];
    let catalog;
    if (args.unpublishedFixture) {
        const fixture = JSON.parse(fs.readFileSync(args.unpublishedFixture, 'utf8'));
        if (fixture.status !== 'UNPUBLISHED_TEST_FIXTURE') fail('not an explicitly UNPUBLISHED test fixture');
        console.log('UNPUBLISHED TEST FIXTURE: offline dry-run archive; not a published companion');
        const localCatalog = path.join(output, 'UNPUBLISHED-test-catalog.json');
        fs.writeFileSync(localCatalog, JSON.stringify(fixture.catalog, null, 2) + '\n');
        catalog = loadCatalog(localCatalog);
        catalog.integrationToolchain = JSON.parse(fs.readFileSync(CATALOG, 'utf8')).integrationToolchain;
        catalogArgs = ['--catalog', localCatalog];
    } else {
        catalog = loadCatalog();
    }
    const host = hostPlatform();
    const parent = catalog.integrationToolchain;
    const base = parent.platforms[host];
    const archive = path.join(output, 'parent.tar.gz');
    await download(base.url, archive, base.sha256);
    // The published parent has legitimate launcher symlinks. Its complete archive is hash-pinned before the native tar
    // reads it into an empty owned directory.
    const unpacked = path.join(output, 'parent');
    fs.mkdirSync(unpacked);
    run('tar', '-xzf', archive, '-C', unpacked);
    const roots = fs.readdirSync(unpacked).map((name) => path.join(unpacked, name));
    if (roots.length !== 1 || !fs.statSync(path.join(roots[0], 'libexec/ablac.bin'), { throwIfNoEntry: false })?.isFile()) fail('unexpected parent toolchain layout');
    const root = path.join(output, 'relocated Abla toolchain');
    fs.renameSync(roots[0], root);
    const originals = snapshot(root);
    // The published integration parent predates the companion catalog. Add only the current catalog; the helper no
    // longer installs any script.
    run('bash', path.join(here, 'package-xtensa-installer.sh'), root);
    const candidate = path.join(output, 'native-package');
    fs.mkdirSync(candidate);
    run('tar', '-xzf', path.resolve(args.nativePackage), '-C', candidate);
    const candidates = fs.readdirSync(candidate).map((name) => path.join(candidate, name));
    if (candidates.length !== 1 || !fs.statSync(path.join(candidates[0], 'bin/abla-install-xtensa'), { throwIfNoEntry: false })?.isFile()) fail('unexpected candidate package layout');
    const installer = path.join(candidates[0], 'bin/abla-install-xtensa');
    const command = [installer, '--toolchain-root', root];
    const version = '23.1.3-1';
    const archiveArgs = args.archive ? ['--archive', path.resolve(args.archive)] : [];
    run(...command, ...catalogArgs, '--version', version, ...archiveArgs);
    run(...command, ...catalogArgs, '--verify');
    run(...command, ...catalogArgs, '--version', version, ...archiveArgs);
    const after = snapshot(root);
    for (const [name, value] of Object.entries(originals)) {
        if (JSON.stringify(after[name]) !== JSON.stringify(value)) fail('installer modified parent file: ' + name);
    }
    const tree = path.join(root, 'lib/abla/xtensa-llvm', version);
    if (!fs.statSync(tree, { throwIfNoEntry: false })?.isDirectory()) fail('verified companion is missing');
    const llc = path.join(tree, 'bin/llc'), opt = path.join(tree, 'bin/opt');
    const fixtureIr = path.join(tree, 'patches.ll');
    const options = ['-mcpu=esp32', '-relocation-model=static', '-O2'];
    run(llc, ...options, '-xtensa-direct-calls', '-xtensa-narrow-branches', '-xtensa-text-section-literals', fixtureIr, '-o', path.join(output, 'patches.s'));
    run(llc, ...options, '-filetype=obj', fixtureIr, '-o', path.join(output, 'patches.o'));
    run(opt, '-passes=default<O2>,globaldce', '-S', fixtureIr, '-o', path.join(output, 'optimized.ll'));
    run(llc, ...options, '-filetype=obj', path.join(output, 'optimized.ll'), '-o', path.join(output, 'optimized.o'));
    const expected = {
        'patches.s': 'b860145a355d1b750c82c45903a8dfa5be685112dd444b9320ef0d109f5ce791',
        'patches.o': '528285e41bb3339affe60bf2cb324602bbed246fc147a5799be27c294150e4d1',
        'optimized.o': '8a12b98e9e44d332e9be540e5941a75b41dd3d9cf12068c20d251c72d4622672',
    };
    const actual = Object.fromEntries(Object.keys(expected).map((name) => [name, fileSha256(path.join(output, name))]));
    if (JSON.stringify(actual) !== JSON.stringify(expected)) fail('installed code generation differs from Nix: ' + JSON.stringify(actual));
    // Exercise the actual DSO as well as the offline fake-file control. Restore it in finally, so even a failed negative
    // leaves this owned prefix usable. The times are copied with touch -r, which keeps their nanoseconds.
    const library = fs.readdirSync(path.join(tree, 'lib')).filter((name) => name.startsWith('libLLVM')).sort().map((name) => path.join(tree, 'lib', name))[0]
        ?? fail('no LLVM library');
    const info = fs.statSync(library, { bigint: true });
    const timestamps = path.join(output, 'library.timestamps');
    fs.writeFileSync(timestamps, '');
    run('touch', '-r', library, timestamps);
    const restoreTimes = () => run('touch', '-r', timestamps, library);
    let original = null;
    try {
        fs.chmodSync(library, 0o644);
        const descriptor = fs.openSync(library, 'r+');
        try {
            const byte = Buffer.alloc(1);
            if (fs.readSync(descriptor, byte, 0, 1, 4096) !== 1) fail('unexpectedly short LLVM library');
            original = byte[0];
            fs.writeSync(descriptor, Buffer.from([original ^ 1]), 0, 1, 4096);
        } finally { fs.closeSync(descriptor); }
        restoreTimes();
        const damaged = fs.statSync(library, { bigint: true });
        if (damaged.size !== info.size) fail('library size changed');
        if (damaged.mtimeNs !== info.mtimeNs) fail('library modification time changed');
        const negative = spawnSync(command[0], [...command.slice(1), ...catalogArgs, '--verify'], { encoding: 'utf8', timeout: 120000 });
        if (negative.status !== 1 || !negative.stderr.includes('file_hash')) fail('stat-preserved DSO corruption was not rejected: ' + JSON.stringify(negative));
        fs.writeFileSync(path.join(output, 'tamper-negative.txt'), negative.stderr);
    } finally {
        if (original !== null) {
            const descriptor = fs.openSync(library, 'r+');
            try { fs.writeSync(descriptor, Buffer.from([original]), 0, 1, 4096); } finally { fs.closeSync(descriptor); }
        }
        restoreTimes();
        fs.chmodSync(library, Number(info.mode & 0o777n));
    }
    run(...command, ...catalogArgs, '--verify');
    const caches = (directory) => fs.readdirSync(directory, { withFileTypes: true })
        .some((entry) => (entry.isDirectory() && !entry.isSymbolicLink()) && (entry.name === '__pycache__' || caches(path.join(directory, entry.name))));
    if (caches(root)) fail('installer wrote Python caches into the toolchain');
    const report = {
        installer: 'native', nativePackageSha256: fileSha256(args.nativePackage), platform: host, parentVersion: parent.version, version,
        unchangedParentFiles: Object.keys(originals).length, statPreservedDsoTamperRejected: true, codegen: actual, status: 'passed',
        unpublishedTestFixture: Boolean(args.unpublishedFixture),
    };
    fs.writeFileSync(path.join(output, 'result.json'), JSON.stringify(report, null, 2) + '\n');
    console.log(JSON.stringify(report, null, 2));
}

main().catch((error) => { console.error(error.message); process.exit(1); });
