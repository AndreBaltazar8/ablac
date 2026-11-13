// Protocol-only fixtures for `ablac analyze --stdio`. Run against a built compiler; never
// executes source compile-time code. Usage: node session.mjs COMPILER
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { pathToFileURL } from 'node:url';

// Absolute, not resolved: build/ablac is a symlink to a launcher that finds its payload
// beside the name it was run as.
const compiler = path.resolve(process.argv[2]);
const root = path.resolve('build/analysis-graph');
fs.mkdirSync(root, { recursive: true });
const uri = (file) => pathToFileURL(file).href;
const bytes = (text) => Buffer.byteLength(text);

class Session {
    constructor(project, { graph = true } = {}) {
        this.id = 0;
        this.project = project;
        this.graph = graph;
    }
    async start() {
        const stderr = fs.openSync(path.join(this.project, 'service.stderr'), 'w');
        this.process = spawn(compiler, ['analyze', '--stdio'], { stdio: ['pipe', 'pipe', stderr] });
        fs.closeSync(stderr);
        this.exit = new Promise((resolve) => this.process.on('close', resolve));
        this.lines = readline.createInterface({ input: this.process.stdout })[Symbol.asyncIterator]();
        const params = { workspaceRoots: [this.project], clientName: 'graph-fixture', clientVersion: '1' };
        if (this.graph) params.analysisMode = 'graph-v1';
        const init = (await this.rpc('initialize', params)).result;
        assert.equal(init.protocolVersion, 1);
        assert.equal(init.capabilities.includes('module-graph-analysis-v1'), this.graph);
        return this;
    }
    async rpc(method, params) {
        this.id += 1;
        this.process.stdin.write(JSON.stringify({ schema: 1, id: this.id, method, params }) + '\n');
        const next = await this.lines.next();
        assert.ok(!next.done, `${method}: the service ended: ${fs.readFileSync(path.join(this.project, 'service.stderr'), 'utf8')}`);
        const result = JSON.parse(next.value);
        assert.equal(result.schema, 1);
        assert.equal(result.id, this.id);
        return result;
    }
    async analyze() {
        const result = (await this.rpc('analyze', {})).result;
        assert.equal(typeof result.revision, 'string');
        for (const document of result.documents) {
            for (const key of ['uri', 'version', 'text', 'symbols', 'occurrences', 'diagnostics']) assert.ok(key in document, key);
            for (const symbol of document.symbols) {
                for (const key of ['id', 'name', 'kind', 'uri', 'range', 'selectionRange', 'detail', 'topLevel']) assert.ok(key in symbol, key);
            }
        }
        return result;
    }
    async close() {
        await this.rpc('shutdown', {});
        this.process.stdin.end();
        assert.equal(await this.exit, 0);
    }
}

const start = (project, options) => new Session(project, options).start();

function fixture(name, files, manifest = 'name = "analysis-fixture"\nentry = "main.ab"\n') {
    const directory = path.join(root, name);
    fs.mkdirSync(directory, { recursive: true });
    fs.writeFileSync(path.join(directory, 'abla.toml'), manifest);
    for (const [file, text] of Object.entries(files)) {
        const target = path.join(directory, file);
        fs.mkdirSync(path.dirname(target), { recursive: true });
        fs.writeFileSync(target, text);
    }
    return directory;
}

const doc = (snapshot, file) => snapshot.documents.find((d) => d.uri === uri(file));
const errors = (snapshot) => snapshot.documents.flatMap((d) => d.diagnostics.map((v) => [d.uri, v.code, v.message]));
const occurrence = (d, name) => d.occurrences.filter((o) => o.name === name);
const noErrors = (snapshot) => assert.deepEqual(errors(snapshot), []);
const code = (response) => response.error.code;

async function simple() {
    const p = fixture('simple', { 'main.ab': '// café 😀\nimport "dep.ab"\nfun main: int = answer()\n', 'dep.ab': 'fun answer: int = 42\n' });
    const s = await start(p);
    const a = await s.analyze();
    noErrors(a);
    const main = doc(a, path.join(p, 'main.ab'));
    const dep = doc(a, path.join(p, 'dep.ab'));
    const target = dep.symbols.find((x) => x.name === 'answer');
    assert.equal(occurrence(main, 'answer')[0].declarationId, target.id);
    assert.ok(occurrence(main, 'answer')[0].type);
    const before = fs.readFileSync(path.join(p, 'dep.ab'));
    const opened = await s.rpc('document/open', { uri: uri(path.join(p, 'dep.ab')), version: 1, text: 'fun answer: string = "x"\n' });
    assert.ok(!('error' in opened));
    const b = await s.analyze();
    assert.ok(errors(b).length > 0, 'cross-file inferred type change was not diagnosed');
    assert.equal(doc(b, path.join(p, 'dep.ab')).version, 1);
    const stale = await s.rpc('document/change', { uri: uri(path.join(p, 'dep.ab')), version: 0, text: '' });
    assert.equal(code(stale), 'stale_document');
    await s.rpc('document/close', { uri: uri(path.join(p, 'dep.ab')) });
    noErrors(await s.analyze());
    assert.ok(fs.readFileSync(path.join(p, 'dep.ab')).equals(before));
    await s.close();
}

async function aliasPrivate() {
    const p = fixture('private', {
        'main.ab': 'import "a.ab" as a\nimport "b.ab" as b\nfun main: int = a.run() + b.run()\n',
        'a.ab': 'private fun hidden: int = 1\nfun run: int = hidden()\n',
        'b.ab': 'private fun hidden: int = 2\nfun run: int = hidden()\n',
    });
    const s = await start(p);
    const a = await s.analyze();
    noErrors(a);
    for (const module of ['a.ab', 'b.ab']) {
        const d = doc(a, path.join(p, module));
        const symbol = d.symbols.find((x) => x.name === 'hidden');
        const refs = occurrence(d, 'hidden');
        assert.equal(refs.length, 2);
        assert.ok(refs.every((x) => x.declarationId === symbol.id), module);
    }
    await s.close();
}

async function genericFields() {
    const p = fixture('generic-fields', { 'main.ab': 'class Box<T>(val item: T) { fun get(): T = item }\nfun <T> identity(value: T): T = value\nfun main: int {\n    val box = Box<int>(identity(42))\n    box.get()\n}\n' });
    const s = await start(p);
    const a = await s.analyze();
    noErrors(a);
    const d = doc(a, path.join(p, 'main.ab'));
    for (const name of ['identity', 'get', 'item']) {
        const refs = occurrence(d, name);
        assert.ok(refs.length >= 2, name);
        assert.ok(refs[refs.length - 1].declarationId, name);
    }
    await s.close();
}

async function noEval() {
    const sentinel = path.join(root, 'forbidden');
    fs.rmSync(sentinel, { force: true });
    const p = fixture('no-eval', { 'main.ab': `import "abla/compiler"\n#compilerGrant("filesystem.write")\nval wrote = #compilerWriteFile(${JSON.stringify(sentinel)}, "bad")\nfun main: int = 0\n` },
        'name = "no-eval"\nentry = "main.ab"\ncompileCapabilities = ["filesystem.write"]\n');
    const s = await start(p);
    const a = await s.analyze();
    assert.ok(!fs.existsSync(sentinel));
    assert.ok(a.pending && !a.complete);
    noErrors(a);
    const v = (await s.rpc('refactor/validate', { baseRevision: a.revision, edits: [], invariants: ['no-new-errors'] })).result;
    assert.equal(v.valid, false);
    assert.ok(v.reason.includes('incomplete'));
    await s.close();
}

async function strict() {
    const p = fixture('strict', { 'main.ab': 'import "a.ab"\nfun main: int = secret()\n', 'a.ab': 'import "b.ab"\nfun exposed: int = 1\n', 'b.ab': 'fun secret: int = 42\n' },
        'name = "strict"\nentry = "main.ab"\nvisibility = "imports"\n');
    const s = await start(p);
    const a = await s.analyze();
    assert.ok(errors(a).some((e) => e[1].includes('IMPORT') || e[1].includes('NAME')), JSON.stringify(errors(a)));
    await s.close();
}

async function symlinks() {
    const p = fixture('symlink', {
        'main.ab': 'import "app/server/main.ab"\nfun main: int = picked()\n',
        'real/app/server/main.ab': 'import "../../lib/lib.ab"\nfun picked: int = fromLexical()\n',
        'lib/lib.ab': 'fun fromLexical: int = 42\n',
        'real/lib/lib.ab': 'fun wrong: string = "wrong"\n',
    });
    const link = path.join(p, 'app/server');
    fs.mkdirSync(path.dirname(link), { recursive: true });
    if (!fs.existsSync(link)) fs.symlinkSync(path.join(p, 'real/app/server'), link, 'dir');
    const s = await start(p);
    const a = await s.analyze();
    noErrors(a);
    assert.ok(a.documents.some((d) => d.uri === uri(path.join(p, 'lib/lib.ab'))));
    await s.close();
}

async function negativeProtocol() {
    const p = fixture('bad-protocol', { 'main.ab': 'fun main: int = 0\n' });
    const s = await start(p);
    assert.equal(code(await s.rpc('document/open', { uri: 'https://invalid/main.ab', version: 1, text: 'fun main: int = 1\n' })), 'invalid_params');
    assert.equal(code(await s.rpc('initialize', {})), 'already_initialized');
    const r = (await s.rpc('analyze', { roots: [path.join(p, 'main.ab'), path.join(p, 'other.ab')] })).result;
    assert.ok(!r.complete && r.issues.length > 0);
    await s.close();
}

async function packages() {
    let p = fixture('packages', { 'main.ab': 'import github("fixture/locked")\nfun main: int = answer()\n' });
    const pkg = path.join(p, '.abla/packages/locked');
    fs.mkdirSync(pkg, { recursive: true });
    const fields = { name: 'locked', provider: 'git', identity: 'github:fixture/locked', source: 'https://github.com/fixture/locked.git', 'selector-kind': 'head', selector: 'HEAD', revision: 'a'.repeat(40), digest: 'b'.repeat(40), entry: 'src/locked.ab' };
    fs.writeFileSync(path.join(p, 'abla.lock'), 'version = 2\n\n[[package]]\n' + Object.entries(fields).map(([k, v]) => `${k} = ${JSON.stringify(v)}\n`).join(''));
    for (const [name, value] of [['revision', fields.revision], ['digest', fields.digest], ['source-url', fields.source]]) fs.writeFileSync(path.join(pkg, name), value);
    fs.writeFileSync(path.join(pkg, 'entry.ab'), 'fun answer: int = 42\n');
    let s = await start(p);
    let a = await s.analyze();
    noErrors(a);
    assert.ok(a.documents.some((d) => d.uri === uri(path.join(pkg, 'entry.ab'))));
    fs.writeFileSync(path.join(pkg, 'revision'), 'c'.repeat(40));
    const b = await s.analyze();
    assert.ok(errors(b).some((e) => e[1].includes('PACKAGE')), JSON.stringify(errors(b)));
    assert.ok(!b.complete);
    await s.close();
    p = fixture('dynamic-provider', { 'main.ab': 'compile fun dependency(): ImportSource = github("fixture/locked")\nimport dependency()\nfun main: int = 0\n' });
    s = await start(p);
    a = await s.analyze();
    assert.ok(errors(a).some((e) => e[1] === 'E_ANALYSIS_CT_REQUIRED'), JSON.stringify(errors(a)));
    assert.ok(!a.complete);
    await s.close();
    p = fixture('shadowed-provider', { 'main.ab': 'val github = (name: string) -> name\nimport github("fixture/locked")\nfun main: int = 0\n' });
    s = await start(p);
    a = await s.analyze();
    assert.ok(errors(a).some((e) => e[1] === 'E_ANALYSIS_CT_REQUIRED'), JSON.stringify(errors(a)));
    await s.close();
}

async function contractSurface() {
    const p = fixture('contract', { 'main.ab': 'import contract "api.ab" as api\nfun main: int = 0\n', 'api.ab': 'private fun implementation: int = missing()\nfun remote(value: int): int = implementation() + value\n' });
    const s = await start(p);
    const a = await s.analyze();
    noErrors(a);
    const d = doc(a, path.join(p, 'api.ab'));
    assert.ok(!d.symbols.some((x) => x.name === 'implementation'));
    assert.ok(occurrence(d, 'implementation').every((x) => !('declarationId' in x) && !('type' in x)), JSON.stringify(d.occurrences));
    await s.close();
}

async function diskRevision() {
    const p = fixture('disk-revision', { 'main.ab': 'import "dep.ab"\nfun main: int = answer()\n', 'dep.ab': 'fun answer: int = 42\n' });
    const s = await start(p);
    const a = await s.analyze();
    assert.ok(a.complete);
    fs.writeFileSync(path.join(p, 'dep.ab'), 'fun answer: int = 43\n');
    let result = (await s.rpc('refactor/validate', { baseRevision: a.revision, edits: [], invariants: ['no-new-errors'] })).result;
    assert.ok(!result.valid && result.reason.includes('revision'), JSON.stringify(result));
    const current = await s.analyze();
    const source = fs.readFileSync(path.join(p, 'main.ab'), 'utf8');
    result = (await s.rpc('refactor/validate', { baseRevision: current.revision, edits: [{ uri: uri(path.join(p, 'main.ab')), start: 0, end: bytes(source), newText: 'val pending = #42\nfun main: int = pending\n' }], invariants: ['no-new-errors'] })).result;
    assert.ok(!result.valid && result.reason.includes('incomplete'), JSON.stringify(result));
    await s.close();
}

async function queries() {
    const p = fixture('queries', { 'main.ab': '// café 😀\nimport "dep.ab"\nfun main: int = answer()\n', 'dep.ab': 'fun answer: int = 42\n' });
    const s = await start(p);
    const a = await s.analyze();
    const main = doc(a, path.join(p, 'main.ab'));
    const call = occurrence(main, 'answer')[0];
    const params = { uri: uri(path.join(p, 'main.ab')), offset: call.range.start, revision: a.revision };
    const definition = (await s.rpc('query/definition', params)).result;
    assert.equal(definition.value.uri, uri(path.join(p, 'dep.ab')));
    const hover = (await s.rpc('query/hover', params)).result;
    assert.equal(hover.value.type, 'i64');
    const refs = (await s.rpc('query/references', params)).result.value;
    assert.equal(refs.length, 2);
    assert.deepEqual(new Set(refs.map((x) => x.uri)), new Set([uri(path.join(p, 'main.ab')), uri(path.join(p, 'dep.ab'))]));
    const empty = (await s.rpc('query/definition', { ...params, offset: 0 })).result;
    assert.equal(empty.value, null);
    for (const offset of [-1, 1.5, bytes(main.text) + 1]) {
        assert.equal(code(await s.rpc('query/definition', { ...params, offset })), 'invalid_params');
    }
    await s.rpc('document/open', { uri: uri(path.join(p, 'dep.ab')), version: 1, text: 'fun answer: string = "changed"\n' });
    assert.equal(code(await s.rpc('query/hover', params)), 'stale_revision');
    const current = { uri: params.uri, offset: params.offset };
    const updated = (await s.rpc('query/hover', current)).result;
    assert.equal(updated.value.type, 'string');
    await s.rpc('document/close', { uri: uri(path.join(p, 'dep.ab')) });
    const restored = (await s.rpc('query/hover', current)).result;
    assert.equal(restored.value.type, 'i64');
    fs.writeFileSync(path.join(p, 'dep.ab'), 'fun answer: string = "on disk"\n');
    const changed = (await s.rpc('query/hover', current)).result;
    assert.equal(changed.value.type, 'string');
    assert.notEqual(changed.revision, restored.revision);
    await s.close();
    const legacy = await start(p, { graph: false });
    assert.equal(code(await legacy.rpc('query/hover', params)), 'method_not_found');
    await legacy.close();
}

async function projections() {
    let p = fixture('projections', { 'main.ab': '// café 😀\nimport "dep.ab"\nfun main: int = answer()\n', 'dep.ab': 'fun answer: int = 42\n' });
    let s = await start(p);
    const full = await s.analyze();
    const without = (object, drop) => Object.fromEntries(Object.entries(object).filter(([k]) => !drop.includes(k)));
    for (const fields of [[], ['diagnostics', 'symbols'], ['occurrences'], ['symbols', 'occurrences', 'diagnostics']]) {
        const result = (await s.rpc('analyze', { fields })).result;
        assert.deepEqual(result.fields, fields);
        assert.deepEqual(without(result, ['fields', 'documents']), without(full, ['documents']));
        assert.equal(result.documents.length, full.documents.length);
        full.documents.forEach((original, index) => {
            const keep = ['uri', 'version', 'text', ...fields];
            assert.deepEqual(result.documents[index], Object.fromEntries(Object.entries(original).filter(([k]) => keep.includes(k))), JSON.stringify(fields));
        });
    }
    // Projection does not poison the full internal cache or subsequent full export.
    assert.deepEqual(await s.analyze(), full);
    const main = doc(full, path.join(p, 'main.ab'));
    const target = occurrence(main, 'answer')[0];
    const result = (await s.rpc('query/definition', { uri: uri(path.join(p, 'main.ab')), offset: target.range.start, revision: full.revision })).result;
    assert.equal(result.value.uri, uri(path.join(p, 'dep.ab')));
    for (const fields of [null, 'symbols', ['unknown'], ['symbols', 'symbols'], [1]]) {
        assert.equal(code(await s.rpc('analyze', { fields })), 'invalid_params', JSON.stringify(fields));
    }
    await s.close();
    p = fixture('projection-ct', { 'main.ab': 'val pending = #42\nfun main: int = pending\n' });
    s = await start(p);
    const a = await s.analyze();
    const b = (await s.rpc('analyze', { fields: ['diagnostics', 'symbols'] })).result;
    assert.deepEqual(b.pending, a.pending);
    assert.equal(b.complete, false);
    assert.ok(b.pending);
    await s.close();
}

const tests = { simple, alias_private: aliasPrivate, generic_fields: genericFields, no_eval: noEval, strict, symlinks, negative_protocol: negativeProtocol, packages, contract_surface: contractSurface, disk_revision: diskRevision, queries, projections };
const filter = process.env.ANALYSIS_TEST_FILTER ? process.env.ANALYSIS_TEST_FILTER.split(',') : null;
for (const [name, test] of Object.entries(tests)) {
    if (filter && !filter.includes(name)) continue;
    await test();
    console.log('ok', name);
}
console.log('analysis graph: protocol fixtures passed');
