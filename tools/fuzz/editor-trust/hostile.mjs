// Opening and editing a hostile project in an editor must run nothing, fetch nothing and write nothing (#1139 programme, "untrusted project in an editor";
// docs/design/language-server.md: the editor policy is no evaluation at all). Each case writes a workspace, drives `ablac analyze --stdio` the way abla-lsp does
// (graph-v2: initialize, analyze, document/open, document/change, analyze, shutdown), and checks that
//   - no canary file appeared (every hostile site tries to create one: compile-time code, a provider, a subparser, a native library, a git config command);
//   - the `git` and `curl` shims on the service's PATH were never run by anything the workspace names;
//   - the workspace holds the same files afterwards (nothing written into it), nothing appeared where a symlink in it points, and the
//     package cache, ABLA_CACHE_DIR and the service's TMPDIR (its private scratch directory, removed when it ends) stayed empty;
//   - the service answered (initialize and analyze) inside the time and memory bound, or refused with a protocol error, and shut down.
// Usage: node hostile.mjs COMPILER [CASE ...]
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { pathToFileURL } from 'node:url';

const compiler = path.resolve(process.argv[2]);
const only = new Set(process.argv.slice(3));
const base = fs.mkdtempSync(path.resolve('build', 'editor-trust.'));
process.on('exit', () => { try { fs.rmSync(base, { recursive: true, force: true }); } catch {} });
const shim = path.join(base, 'shim');
fs.mkdirSync(shim);
const shimLog = path.join(base, 'shim.log');
for (const tool of ['git', 'curl', 'wget', 'ssh', 'nc']) {
    fs.writeFileSync(path.join(shim, tool), `#!/bin/sh\necho "${tool} $PWD $*" >> ${shimLog}\nexit 1\n`, { mode: 0o755 });
}
const toml = (lines) => lines.join('\n') + '\n';
const ALL = '["filesystem.read", "filesystem.write", "environment", "process.io", "network", "trusted.native"]';
let n = 0;
const cases = [];
const add = (name, make, options = {}) => cases.push({ name, make, ...options });
const canaryOf = (dir) => path.join(path.dirname(dir), `canary-${path.basename(dir)}`);

// A project that grants itself everything and runs a process and writes a file from every compile-time position.
const evil = (canary) => `compilerRunProcess(["touch", "${canary}"]); compilerWriteFile("${canary}.w", "x")`;
add('ct-expression', (dir, canary) => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"', `compileCapabilities = ${ALL}`]),
    'main.ab': `import "abla/compiler"\n#compilerGrant("process.io")\n#compilerGrant("filesystem.write")\n\ncompile fun hostile(): int {\n    compilerRunProcess(["touch", "${canary}"])\n    compilerWriteFile("${canary}.w", "x")\n    1\n}\nval x = #hostile()\nfun main: int = x\n`,
}));
add('ct-action-grant', (dir, canary) => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"', 'compileCapabilities = ["process.io"]']),
    'main.ab': `import "abla/compiler"\n#compilerGrant("process.io")\nval s = #compilerRunProcess(["touch", "${canary}"])\nfun main: int = 0\n`,
}));
add('ct-default-argument', (dir, canary) => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"', `compileCapabilities = ${ALL}`]),
    'main.ab': `import "abla/compiler"\n#compilerGrant("process.io")\ncompile fun hostile(): int {\n    compilerRunProcess(["touch", "${canary}"])\n    1\n}\nfun f(a: int = #hostile()): int = a\nfun main: int = f()\n`,
}));
add('subparser', (dir, canary) => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"', `compileCapabilities = ${ALL}`]),
    'ext.ab': `import "abla/compiler"\nimport "abla/compiler/parser"\n#compilerGrant("process.io")\ncompile fun evilHandler(cursor: ParserCursor): SyntaxExpression {\n    parserExpect(cursor, "x")\n    compilerRunProcess(["touch", "${canary}"])\n    syntaxInteger(1)\n}\n#compilerRegisterSubparser("evil", evilHandler)\n`,
    'main.ab': `import "ext.ab"\nfun main: int = $evil x\n`,
}));
add('import-provider', (dir, canary) => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"', `compileCapabilities = ${ALL}`]),
    'provider.ab': `import "abla/compiler"\n#compilerGrant("process.io")\ncompile fun resolveGen(): ResolvedImport {\n    compilerRunProcess(["touch", "${canary}"])\n    resolvedImport("r1", "src/gen.ab", [importFile("abla.toml", "name = \\"gen\\"\\nentry = \\"src/gen.ab\\"\\n"), importFile("src/gen.ab", "fun genAnswer: int = 1\\n")])\n}\ncompile fun gen(): ImportSource = importSource("gen", "test:gen", "v1", resolveGen)\n`,
    'main.ab': `import "provider.ab"\nimport gen()\nfun main: int = genAnswer()\n`,
}));
add('github-import', () => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"']),
    'main.ab': `import github("evil/repo")\nfun main: int = 0\n`,
}));
add('git-dependency-unlocked', (dir) => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"', '', '[dependencies]', `dep = { git = "${dir}/dep.git", rev = "0123456789abcdef0123456789abcdef01234567" }`]),
    'main.ab': `import "dep"\nfun main: int = 0\n`,
}));
add('prepared-copy-with-hostile-git-config', (dir, canary) => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"']),
    'main.ab': `import gitImportSource("dep", "${dir}/dep.git", "branch", "main")\nfun main: int = depValue()\n`,
}), { setup(dir, canary, env, run) {
    const repo = path.join(dir, 'dep.git');
    fs.mkdirSync(repo);
    const g = (...a) => spawnSync('git', ['-C', repo, '-c', 'user.name=t', '-c', 'user.email=t@e.invalid', ...a], { env: { ...env, PATH: process.env.PATH } });
    g('init', '-q', '--initial-branch=main');
    fs.writeFileSync(path.join(repo, 'abla.toml'), 'name = "dep"\nentry = "dep.ab"\n');
    fs.writeFileSync(path.join(repo, 'dep.ab'), 'fun depValue(): int = 7\n');
    g('add', '-A'); g('commit', '-q', '-m', 'c');
    run(['package', 'update', '--project', dir]);
    run(['package', 'install', '--project', dir]);
    const hostile = `[core]\n\tfsmonitor = touch ${canary}; echo\n`;
    const copies = [path.join(dir, '.abla/packages/dep/source/.git/config')];
    const found = spawnSync('find', [env.ABLA_PACKAGE_CACHE, '-path', '*/source/.git/config'], { encoding: 'utf8' }).stdout.trim().split('\n').filter(Boolean);
    for (const f of [...copies, ...found]) if (fs.existsSync(f)) fs.appendFileSync(f, hostile);
    for (const f of [...copies, ...found]) if (!fs.existsSync(f)) console.log('note: no ' + f);
    for (const f of fs.readdirSync(env.ABLA_PACKAGE_CACHE)) void f;
    env.SNAPSHOT_CACHE = '1';
} });
add('native-library', (dir, canary) => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"', 'nativeLibraries = ["evil"]', `compileCapabilities = ${ALL}`]),
    'main.ab': `fun main: int = 0\n`,
    'libevil.so': '\x7fELF-not-a-library',
}));
add('hostile-build-dir', (dir, canary) => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"']),
    'main.ab': `fun main: int = 0\n`,
    'build/main': `#!/bin/sh\ntouch ${canary}\n`,
    'build/libevil.so': 'x',
    'build/ablac-cache/jit/x.o': 'x',
}));
const selfTrusting = (dir, canary) => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"', `compileCapabilities = ${ALL}`, '', '[editor]', 'trusted = true', 'compileTime = true', '', '[lsp]', 'trusted = true']),
    '.abla-trusted': 'yes\n',
    '.vscode/settings.json': '{"abla.trustedProject": true, "abla.compileTime": true}\n',
    'abla-lsp.json': '{"trusted": true}\n',
    'main.ab': `import "abla/compiler"\n#compilerGrant("process.io")\nval s = #compilerRunProcess(["touch", "${canary}"])\nfun main: int = 0\n`,
});
add('self-trusting-project', selfTrusting);
add('initialize-trust-flags', selfTrusting, { init: { trusted: true, trustedProject: true, trust: 'full', allowCompileTime: true, compileTime: true, policy: { compileTime: true, evaluate: true }, capabilities: ['process.io', 'filesystem.write'], initializationOptions: { trusted: true } } });
add('initialize-without-mode', selfTrusting, { init: { analysisMode: undefined } });
// Every compile-time site in one project, so one analysis session covers them (tools/test-editor-trust.sh): each module tries to create its own canary.
add('combined', (dir, canary) => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"', 'nativeLibraries = ["evil"]', `compileCapabilities = ${ALL}`, '', '[editor]', 'trusted = true']),
    '.vscode/settings.json': '{"abla.trustedProject": true, "abla.compiler.path": "./evil"}\n',
    'libevil.so': '\x7fELF-not-a-library',
    'build/main': `#!/bin/sh\ntouch ${canary}.build\n`,
    'm1.ab': `import "abla/compiler"\n#compilerGrant("process.io")\n#compilerGrant("filesystem.write")\ncompile fun hostile(): int {\n    compilerRunProcess(["touch", "${canary}.expression"])\n    compilerWriteFile("${canary}.w", "x")\n    1\n}\nval x = #hostile()\n`,
    'm2.ab': `import "abla/compiler"\n#compilerGrant("process.io")\nval s = #compilerRunProcess(["touch", "${canary}.action"])\n`,
    'm3.ab': `import "abla/compiler"\n#compilerGrant("process.io")\ncompile fun hostile(): int {\n    compilerRunProcess(["touch", "${canary}.default"])\n    1\n}\nfun f(a: int = #hostile()): int = a\n`,
    'ext.ab': `import "abla/compiler"\nimport "abla/compiler/parser"\n#compilerGrant("process.io")\ncompile fun evilHandler(cursor: ParserCursor): SyntaxExpression {\n    parserExpect(cursor, "x")\n    compilerRunProcess(["touch", "${canary}.subparser"])\n    syntaxInteger(1)\n}\n#compilerRegisterSubparser("evil", evilHandler)\n`,
    'm4.ab': `import "ext.ab"\nfun sub: int = $evil x\n`,
    'provider.ab': `import "abla/compiler"\n#compilerGrant("process.io")\ncompile fun resolveGen(): ResolvedImport {\n    compilerRunProcess(["touch", "${canary}.provider"])\n    resolvedImport("r1", "src/gen.ab", [importFile("abla.toml", "name = \\"gen\\"\\nentry = \\"src/gen.ab\\"\\n"), importFile("src/gen.ab", "fun genAnswer: int = 1\\n")])\n}\ncompile fun gen(): ImportSource = importSource("gen", "test:gen", "v1", resolveGen)\n`,
    'm5.ab': `import "provider.ab"\nimport gen()\nfun g: int = genAnswer()\n`,
    'm6.ab': `import github("evil/repo")\nimport gitImportSource("dep", "${dir}/dep.git", "branch", "main")\nfun h: int = 0\n`,
    'cycle-a.ab': `import "cycle-b.ab"\nfun fa: int = 1\n`,
    'cycle-b.ab': `import "cycle-a.ab"\nfun fb: int = 1\n`,
    '@link:loop': '.',
    '@link:zero.ab': '/dev/zero',
    '@fifo:pipe.ab': '',
    'main.ab': `import "m1.ab"\nimport "m2.ab"\nimport "m3.ab"\nimport "m4.ab"\nimport "m5.ab"\nimport "m6.ab"\nimport "cycle-a.ab"\nimport "loop/m1.ab"\nimport "zero.ab"\nimport "pipe.ab"\nimport "/etc/passwd"\nimport "../../../../../etc/hostname"\nfun main: int = 0\n`,
}), { init: { trusted: true, trustedProject: true, trust: 'full', allowCompileTime: true, compileTime: true, policy: { compileTime: true, evaluate: true }, capabilities: ['process.io', 'filesystem.write'], initializationOptions: { trusted: true } }, minPending: 4 });
// Resource bounds.
add('deep-nesting', () => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"']),
    'main.ab': `fun main: int = ${'('.repeat(200000)}1${')'.repeat(200000)}\n`,
}), { bound: 'respond' });
add('deep-blocks', () => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"']),
    'main.ab': `fun main: int {\n${'if (true) {\n'.repeat(50000)}1\n${'}\n'.repeat(50000)}0\n}\n`,
}), { bound: 'respond' });
add('huge-file', () => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"']),
    'main.ab': `fun main: int = 0\n// ${'a'.repeat(64 * 1024 * 1024)}\n`,
}), { bound: 'respond' });
add('many-modules', () => {
    const files = { 'abla.toml': toml(['name = "evil"', 'entry = "main.ab"']) };
    let main = '';
    for (let i = 0; i < 5000; i++) { files[`m${i}.ab`] = `fun f${i}: int = ${i}\n`; main += `import "m${i}.ab"\n`; }
    files['main.ab'] = `${main}fun main: int = 0\n`;
    return files;
}, { bound: 'respond' });
add('import-cycle', () => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"']),
    'main.ab': `import "a.ab"\nfun main: int = 0\n`,
    'a.ab': `import "b.ab"\nfun fa: int = 1\n`,
    'b.ab': `import "a.ab"\nfun fb: int = 1\n`,
}), { bound: 'respond' });
add('symlink-loop', (dir) => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"']),
    'main.ab': `import "loop/x.ab"\nfun main: int = 0\n`,
    '@link:loop': '.',
}), { bound: 'respond' });
add('fifo-import', (dir) => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"']),
    'main.ab': `import "pipe.ab"\nfun main: int = 0\n`,
    '@fifo:pipe.ab': '',
}), { bound: 'respond' });
add('dev-zero-import', () => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"']),
    'main.ab': `import "zero.ab"\nfun main: int = 0\n`,
    '@link:zero.ab': '/dev/zero',
}), { bound: 'respond' });
add('import-outside-root', () => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"']),
    'main.ab': `import "/etc/passwd"\nimport "../../../../../etc/hostname"\nfun main: int = 0\n`,
}), { bound: 'respond' });
add('workspace-is-root-link', () => ({}), { workspace: '/', bound: 'respond' });
// The standard library's literal handlers do run in the editor, and the evaluator keeps state between their steps: that must go in the
// service's own directory, not the workspace's build/ (#1139 area 8), nor where a symlinked build/ points.
const literals = () => ({
    'abla.toml': toml(['name = "evil"', 'entry = "main.ab"']),
    'main.ab': 'import "abla/regex"\nimport "abla/json"\nfun main: int {\n    val r = $regex("(?<x>a+)b")\n    val p = $regex("ab+")\n' +
        '    val j = $json { "a": [1, 2], "b": "c" }\n    0\n}\n',
});
add('stdlib-literals', literals);
add('stdlib-literals-build-link', (dir) => ({ ...literals(), '@link:build': `${dir}-outside` }), { outside: true });

function write(dir, files) {
    for (const [name, contents] of Object.entries(files)) {
        if (name.startsWith('@link:')) { fs.symlinkSync(contents, path.join(dir, name.slice(6))); continue; }
        if (name.startsWith('@fifo:')) { const p = path.join(dir, name.slice(6)); fs.mkdirSync(path.dirname(p), { recursive: true }); spawnSyncMk(p); continue; }
        const p = path.join(dir, name);
        fs.mkdirSync(path.dirname(p), { recursive: true });
        fs.writeFileSync(p, contents);
    }
}
import { spawnSync } from 'node:child_process';
const spawnSyncMk = (p) => spawnSync('mkfifo', [p]);
const tree = (dir) => {
    const out = [];
    const walk = (d, depth) => {
        if (depth > 12) return;
        let entries; try { entries = fs.readdirSync(d, { withFileTypes: true }); } catch { return; }
        for (const e of entries) {
            const p = path.join(d, e.name);
            if (e.name === 'service.stderr') continue;
            let st; try { st = fs.lstatSync(p); } catch { continue; }
            out.push(`${path.relative(dir, p)} ${st.isDirectory() ? 'd' : st.isSymbolicLink() ? 'l' : st.isFIFO() ? 'p' : st.size}`);
            if (st.isDirectory()) walk(p, depth + 1);
        }
    };
    walk(dir, 0);
    return out.sort().join('\n');
};

async function session(workspace, dir, env, timeoutMs, edit, extra = {}) {
    const stderrPath = path.join(base, `${path.basename(dir)}.stderr`);
    const stderr = fs.openSync(stderrPath, 'w');
    const child = spawn('/bin/sh', ['-c', 'ulimit -v 8388608; exec "$0" analyze --stdio', compiler], { stdio: ['pipe', 'pipe', stderr], env, cwd: dir });
    fs.closeSync(stderr);
    const exit = new Promise((resolve) => child.on('close', (code, signal) => resolve({ code, signal })));
    const lines = readline.createInterface({ input: child.stdout })[Symbol.asyncIterator]();
    let id = 0;
    let peak = 0;
    const sampler = setInterval(() => { try { const m = /VmHWM:\s+(\d+)/.exec(fs.readFileSync(`/proc/${child.pid}/status`, 'utf8')); if (m) peak = Math.max(peak, Number(m[1])); } catch {} }, 100);
    const rpc = (method, params) => new Promise((resolve) => {
        id += 1;
        const mine = id;
        const timer = setTimeout(() => resolve({ timeout: true }), timeoutMs);
        child.stdin.write(JSON.stringify({ schema: 1, id: mine, method, params }) + '\n', () => {});
        lines.next().then((next) => { clearTimeout(timer); resolve(next.done ? { ended: true } : JSON.parse(next.value)); });
    });
    const summary = { steps: [], peakKiB: 0 };
    const step = async (method, params) => { const r = await rpc(method, params); summary.steps.push(`${method}:${r.timeout ? 'timeout' : r.ended ? 'ended' : r.error ? 'error ' + (r.error.code ?? '') : 'ok'}`); return r; };
    try {
        let r = await step('initialize', { workspaceRoots: [workspace], clientName: 'hostile', clientVersion: '1', analysisMode: 'graph-v2', ...extra });
        if (r.result) {
            r = await step('analyze', {});
            if (r.result && r.result.documents) { const codes = new Set(); for (const d of r.result.documents) for (const x of d.diagnostics ?? []) codes.add(x.code); for (const p of r.result.pending ?? []) codes.add('pending:' + p.code); summary.pending = (r.result.pending ?? []).length; summary.codes = [...codes].slice(0, 4); }
            const main = path.join(dir, 'main.ab');
            if (r.result && edit && fs.existsSync(main)) {
                const text = fs.readFileSync(main, 'utf8').slice(0, 4096);
                await step('document/open', { uri: pathToFileURL(main).href, version: 1, text });
                await step('document/change', { uri: pathToFileURL(main).href, version: 2, text: text + '\n// edit\n' });
                await step('analyze', {});
            }
        }
        if (!r.timeout && !r.ended) await step('shutdown', {});
    } finally {
        clearInterval(sampler);
        summary.peakKiB = peak;
        try { child.stdin.end(); } catch {}
        const done = await Promise.race([exit, new Promise((resolve) => setTimeout(() => resolve(null), 3000))]);
        if (done === null) { child.kill('SIGKILL'); summary.killed = true; summary.exit = await exit; } else summary.exit = done;
    }
    return summary;
}

const CONTROL = process.env.EDITOR_TRUST_CONTROL === '1';
let failures = 0;
const report = (name, ok, text) => { if (!ok) failures += 1; console.log(`${ok ? 'ok  ' : 'FAIL'} ${name}${text ? ': ' + text : ''}`); };
for (const c of cases) {
    if (only.size && !only.has(c.name)) continue;
    n += 1;
    const dir = path.join(base, c.name);
    fs.mkdirSync(dir);
    const canary = canaryOf(dir);
    write(dir, c.make(dir, canary));
    const cache = path.join(base, `cache-${c.name}`);
    fs.mkdirSync(cache);
    const env = { PATH: `${shim}:${process.env.PATH}`, HOME: path.join(base, `home-${c.name}`), ABLA_PACKAGE_CACHE: cache, ABLA_CACHE_DIR: path.join(base, `abla-cache-${c.name}`), ABLA_SYSROOT: process.env.ABLA_SYSROOT ?? '', ABLA_STDLIB: process.env.ABLA_STDLIB ?? '', ABLA_DEBUG: '0' };
    fs.mkdirSync(env.HOME);
    env.TMPDIR = path.join(base, `tmp-${c.name}`);
    fs.mkdirSync(env.TMPDIR);
    if (c.outside) fs.mkdirSync(`${dir}-outside`);
    if (c.setup) {
        const run = (args) => spawnSync(compiler, args, { env: { ...env, PATH: process.env.PATH }, cwd: dir, encoding: 'utf8', timeout: 120000 });
        c.setup(dir, canary, env, run);
    }
    const before = tree(dir);
    if (CONTROL) {
        const built = spawnSync(compiler, c.name === 'import-provider' ? ['package', 'update', '--project', dir] : ['build', '--project', dir, '-o', path.join(dir, 'out-bin'), '--fast', '--no-cache'], { env, cwd: dir, encoding: 'utf8', timeout: 120000 });
        const created = fs.readdirSync(path.dirname(dir)).some((f) => f.startsWith(path.basename(canary)));
        report('control ' + c.name, true, 'ablac ' + (c.name === 'import-provider' ? 'package update' : 'build') + ' status ' + built.status + ', canary ' + (created ? 'CREATED (the site is live in a build)' : 'absent (this site does not act in a build either)'));
        for (const f of fs.readdirSync(path.dirname(dir))) if (f.startsWith(path.basename(canary))) try { fs.rmSync(path.join(path.dirname(dir), f)); } catch {}
        continue;
    }
    const started = Date.now();
    const summary = await session(c.workspace ?? dir, dir, env, c.bound === 'respond' ? 60000 : 30000, true, c.init ?? {});
    const seconds = ((Date.now() - started) / 1000).toFixed(1);
    const problems = [];
    for (const f of fs.readdirSync(path.dirname(dir))) if (f.startsWith(path.basename(canary))) problems.push(`canary ${f} exists (code ran)`);
    const ran = fs.existsSync(shimLog) ? fs.readFileSync(shimLog, 'utf8').trim().split('\n').filter((l) => l.includes(base)) : [];
    if (ran.length) problems.push(`shim tools ran: ${ran.slice(0, 3).join(' | ')}`);
    if (c.workspace === undefined && tree(dir) !== before) problems.push('the workspace changed');
    if (!c.setup && fs.readdirSync(cache).length) problems.push(`the package cache holds ${fs.readdirSync(cache).join(',')}`);
    if (fs.existsSync(env.ABLA_CACHE_DIR) && fs.readdirSync(env.ABLA_CACHE_DIR).length) problems.push('ABLA_CACHE_DIR was written');
    if (c.outside && fs.readdirSync(`${dir}-outside`).length) problems.push(`written through the build/ symlink: ${fs.readdirSync(`${dir}-outside`).join(',')}`);
    if (fs.readdirSync(env.TMPDIR).length) problems.push(`the service left ${fs.readdirSync(env.TMPDIR).join(',')} in its TMPDIR`);
    if (summary.steps.some((s) => s.endsWith('timeout'))) problems.push('no answer in time');
    if (summary.killed) problems.push('had to be killed');
    if (c.minPending !== undefined && (summary.pending ?? 0) < c.minPending) problems.push(`only ${summary.pending ?? 0} blocked compile-time sites reported (the workspace has more): the analysis stopped early`);
    if (summary.peakKiB > 6 * 1024 * 1024) problems.push(`peak ${Math.round(summary.peakKiB / 1024)} MiB`);
    fs.writeFileSync(shimLog, '');
    report(c.name, problems.length === 0, `${problems.join('; ') || summary.steps.join(' ')} codes=${(summary.codes ?? []).join(',')} [${seconds}s, ${Math.round(summary.peakKiB / 1024)} MiB, exit ${summary.exit?.code ?? summary.exit?.signal}]`);
}
if (failures) { console.error(`editor trust: ${failures} case(s) failed`); process.exit(1); }
console.log('editor trust: every hostile workspace was analyzed without running, fetching or writing anything');
