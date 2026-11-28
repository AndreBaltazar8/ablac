// Protocol-only fixtures for `ablac analyze --stdio`. Run against a built compiler; never
// executes a package's or the user's compile-time code (the standard library's subparsers are expanded). Usage: node session.mjs COMPILER
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath, pathToFileURL } from 'node:url';

// Absolute, not resolved: build/ablac is a symlink to a launcher that finds its payload
// beside the name it was run as.
const compiler = path.resolve(process.argv[2]);
const root = path.resolve('build/analysis-graph');
fs.mkdirSync(root, { recursive: true });
const uri = (file) => pathToFileURL(file).href;
const bytes = (text) => Buffer.byteLength(text);

class Session {
    constructor(project, { mode = 'graph-v1', initialize = true, env = process.env, log = 'service.stderr', unusedImports = false } = {}) {
        this.id = 0;
        this.project = project;
        this.mode = mode;
        this.initialize = initialize;
        this.unusedImports = unusedImports;
        this.env = env;
        this.log = path.join(project, log);
    }
    async start() {
        const stderr = fs.openSync(this.log, 'w');
        this.process = spawn(compiler, ['analyze', '--stdio'], { stdio: ['pipe', 'pipe', stderr], env: this.env });
        fs.closeSync(stderr);
        this.exit = new Promise((resolve) => this.process.on('close', resolve));
        this.lines = readline.createInterface({ input: this.process.stdout })[Symbol.asyncIterator]();
        if (!this.initialize) return this;
        const params = { workspaceRoots: [this.project], clientName: 'graph-fixture', clientVersion: '1', analysisMode: this.mode, unusedImports: this.unusedImports };
        const init = (await this.rpc('initialize', params)).result;
        assert.equal(init.protocolVersion, 1);
        assert.ok(init.capabilities.includes('module-graph-analysis-v1'));
        assert.equal(init.capabilities.includes('stable-declaration-ids-v1'), this.mode === 'graph-v2');
        return this;
    }
    async rpc(method, params) {
        this.id += 1;
        this.process.stdin.write(JSON.stringify({ schema: 1, id: this.id, method, params }) + '\n');
        const next = await this.lines.next();
        assert.ok(!next.done, `${method}: the service ended: ${fs.readFileSync(this.log, 'utf8')}`);
        const result = JSON.parse(next.value);
        assert.equal(result.schema, 1);
        assert.equal(result.id, this.id);
        return result;
    }
    async analyze() {
        const result = (await this.rpc('analyze', {})).result;
        assert.equal(typeof result.revision, 'string');
        assert.equal(result.analysisMode, this.mode);
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
    assert.equal(code(await s.rpc('initialize', { analysisMode: 'graph-v1' })), 'already_initialized');
    const r = (await s.rpc('analyze', { roots: [path.join(p, 'main.ab'), path.join(p, 'other.ab')] })).result;
    assert.ok(!r.complete && r.issues.length > 0);
    await s.close();
    // The legacy mode (an initialize without analysisMode) is gone (#832): refused, and so is anything before an
    // accepted initialize.
    const bare = await start(p, { initialize: false });
    const params = { workspaceRoots: [p], clientName: 'graph-fixture', clientVersion: '1' };
    assert.equal(code(await bare.rpc('initialize', params)), 'unsupported_analysis_mode');
    assert.equal(code(await bare.rpc('analyze', {})), 'not_initialized');
    assert.ok((await bare.rpc('initialize', { ...params, analysisMode: 'graph-v1' })).result.capabilities.includes('module-graph-analysis-v1'));
    await bare.close();
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
    // Compile-time expressions in a contract-only implementation are inert.
    const uriPath = uri(path.join(p, 'api.ab'));
    const text = 'private fun implementation: int = #42\nfun remote(value: int): int = implementation() + value\n';
    await s.rpc('document/open', { uri: uriPath, version: 1, text });
    assert.deepEqual((await s.analyze()).pending, []);
    const entry = uri(path.join(p, 'main.ab'));
    await s.rpc('document/open', { uri: entry, version: 1, text: 'import "api.ab"\nfun main: int = 0\n' });
    const edited = await s.analyze();
    assert.equal(edited.complete, false);
    assert.equal(edited.pending.length, 1);
    assert.equal(edited.pending[0].uri, uriPath);
    assert.equal(text.slice(edited.pending[0].range.start, edited.pending[0].range.end), '#42');
    await s.rpc('document/close', { uri: entry });
    assert.deepEqual((await s.analyze()).pending, []);
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
}

// A type is written as text (`s: Square`, `Square(2)`, `: Shape`) and a module imported under an alias is written as a qualifier (`geo.area`):
// both name the declaration they mean, so find-references on a class finds its uses and a rename of an aliased function is not missing its uses.
async function typeNames(mode) {
    const shapes = [
        'class Square(val side: int) {',
        '    fun grow(): Square = Square(side + 1)',
        '}',
        'interface Shape { fun sides(): int }',
        'fun area(s: Square): int = s.side * s.side',
        'val unit = 1',
        'private class Twin(val v: int)',
        'fun twinShapes(): int = Twin(1).v',
        '',
    ].join('\n');
    const util = [
        'class Plain(val n: int)',
        'class Holder(val Plain: int)',
        'class Item(val n: int)',
        'fun makePlain(): Plain = Plain(1)',
        'fun usePlain(p: Plain): int = p.n',
        'fun <Item> pass(x: Item): Item = x',
        'private class Twin(val v: int)',
        'fun twinUtil(): int = Twin(2).v',
        '',
    ].join('\n');
    const main = [
        'import "shapes.ab" as geo',
        'import "util.ab"',
        'fun main: int {',
        '    val s: geo.Square = geo.Square(2)',
        '    val p: Plain = makePlain()',
        '    return geo.area(s.grow()) + geo.unit + usePlain(p) + Plain(3).n + Holder(4).Plain + pass(5) + twinShapes() + twinUtil()',
        '}',
        '',
    ].join('\n');
    const p = fixture(`type-names-${mode}`, { 'main.ab': main, 'shapes.ab': shapes, 'util.ab': util });
    const s = await start(p, { mode });
    const a = await s.analyze();
    const main_ = doc(a, path.join(p, 'main.ab'));
    const shapes_ = doc(a, path.join(p, 'shapes.ab'));
    const util_ = doc(a, path.join(p, 'util.ab'));
    const symbol = (d, name, kind) => d.symbols.find((x) => x.name === name && (!kind || x.kind === kind));
    const square = symbol(shapes_, 'Square', 'class');
    const shape = symbol(shapes_, 'Shape', 'interface');
    const area = symbol(shapes_, 'area');
    const unit = symbol(shapes_, 'unit');
    const plain = symbol(util_, 'Plain', 'class');
    const item = symbol(util_, 'Item', 'class');
    for (const x of [square, shape, area, unit, plain, item]) assert.ok(x, 'a declaration the fixture needs');
    const before = (d, o) => d.text.slice(Math.max(0, o.range.start - 1), o.range.start);
    const ids = (d, name) => occurrence(d, name).map((o) => [before(d, o), o.declarationId]);
    // the class's uses in its own module: the return type, the constructor call, the parameter type of `area`
    assert.deepEqual(ids(shapes_, 'Square').map(([, id]) => id), [square.id, square.id, square.id, square.id]);
    // from another module, through the alias: the type annotation and the constructor call
    assert.deepEqual(ids(main_, 'Square'), [['.', square.id], ['.', square.id]]);
    // a function and a value through the alias
    assert.deepEqual(ids(main_, 'area'), [['.', area.id]]);
    assert.deepEqual(ids(main_, 'unit'), [['.', unit.id]]);
    // a plain import: the annotation and the constructor call name the class; a field spelled like the class (`.Plain`) is the field's
    const plainUses = occurrence(main_, 'Plain');
    assert.equal(plainUses.length, 3);
    assert.deepEqual(plainUses.filter((o) => before(main_, o) !== '.').map((o) => o.declarationId), [plain.id, plain.id]);
    assert.notEqual(plainUses.find((o) => before(main_, o) === '.').declarationId, plain.id);
    // a type parameter (`<Item>`, `x: Item`, `: Item`) is not the class of that name
    const itemUses = occurrence(util_, 'Item');
    assert.equal(itemUses.length, 4);
    assert.equal(itemUses.filter((o) => o.declarationId === item.id).length, 1, 'only the class declaration names the class Item');
    // two modules' private classes of one name are not told apart by name: unnamed, not guessed
    for (const d of [shapes_, util_]) {
        const twins = occurrence(d, 'Twin').filter((o) => !d.symbols.some((x) => x.name === 'Twin' && x.selectionRange.start === o.range.start));
        assert.ok(twins.length > 0);
        for (const o of twins) assert.equal(o.declarationId, undefined, 'an ambiguous name is left unnamed');
    }
    // find-references on the class: its declaration and every use, in both modules
    const at = (d, o) => ({ uri: d.uri, offset: o.range.start });
    const classReferences = (await s.rpc('query/references', { ...at(shapes_, occurrence(shapes_, 'Square')[0]) })).result.value;
    const starts = (list) => list.map((r) => `${r.uri.split('/').pop()}:${r.range.start}`).sort();
    assert.equal(classReferences.length, 6, `references of Square: ${starts(classReferences)}`);
    // a rename of an aliased function is an edit of every reference of its declaration: the use through the alias is in it
    const areaReferences = (await s.rpc('query/references', at(shapes_, occurrence(shapes_, 'area')[0]))).result.value;
    assert.deepEqual(starts(areaReferences), [`main.ab:${occurrence(main_, 'area')[0].range.start}`, `shapes.ab:${occurrence(shapes_, 'area')[0].range.start}`].sort());
    // and from the use, hover and definition find the declaration
    const use = at(main_, occurrence(main_, 'area')[0]);
    assert.equal((await s.rpc('query/definition', use)).result.value.uri, shapes_.uri);
    await s.close();
}

// The uses of a `var` parameter (a mutable borrow, not a field), a call of a function-typed parameter, and a method called without a receiver inside
// its class each name the declaration they mean: they once named none (the exporter called a function's `var` parameter a field, so sema's
// identity for its uses matched nothing; the call of a local and a call on `this` were not recorded as uses).
async function localNames(mode) {
    const main = [
        'class Box(var size: Int) {',
        '    fun twice(n: Int): Int = n * 2',
        '    fun use(n: Int): Int = twice(n) + size',
        '}',
        'fun fill(var out: array<Int>, var box: Box, n: Int, f: (Int) -> Int): Int {',
        '    out.append(n)',
        '    box.size = 3',
        '    val g = f(n)',
        '    return g + out.size + box.size + f(n)',
        '}',
        'fun other(var out: array<Int>): Int {',
        '    out.append(1)',
        '    return out.size',
        '}',
        'fun main: Int {',
        '    val xs: array<Int> = []',
        '    return fill(xs, Box(1), 2, { q -> q + 1 }) + Box(2).use(3) + Box(3).twice(4) + other(xs)',
        '}',
        '',
    ].join('\n').replace(/Int/g, 'int');
    const p = fixture(`local-names-${mode}`, { 'main.ab': main });
    const s = await start(p, { mode });
    const a = await s.analyze();
    const d = doc(a, path.join(p, 'main.ab'));
    const lineOf = (o) => d.text.slice(0, o.range.start).split('\n').length;
    const inFunction = (name, first, last) => occurrence(d, name).filter((o) => lineOf(o) >= first && lineOf(o) <= last);
    // `out` of fill (lines 5-9): the parameter and its two uses name one declaration; `other`'s `out` (lines 11-14) another
    const fillOut = inFunction('out', 5, 9);
    assert.equal(fillOut.length, 3);
    assert.ok(fillOut.every((o) => o.declarationId), 'every use of a var parameter names it');
    assert.equal(new Set(fillOut.map((o) => o.declarationId)).size, 1);
    const otherOut = inFunction('out', 11, 14);
    assert.equal(otherOut.length, 3);
    assert.equal(new Set(otherOut.map((o) => o.declarationId)).size, 1);
    assert.notEqual(otherOut[0].declarationId, fillOut[0].declarationId);
    const fillBox = inFunction('box', 5, 9);
    assert.ok(fillBox.length === 3 && fillBox.every((o) => o.declarationId) && new Set(fillBox.map((o) => o.declarationId)).size === 1);
    // a class's own `var` constructor parameter stays its field: `box.size` names the field, as `size` in the method does
    const fieldIds = new Set(occurrence(d, 'size').filter((o) => o.declarationId).map((o) => o.declarationId));
    assert.ok([...fieldIds].some((id) => /field/.test(id)), 'the field of Box');
    // the call of a function-typed parameter names the parameter
    const f = inFunction('f', 5, 9);
    assert.equal(f.length, 3);
    assert.ok(f.every((o) => o.declarationId) && new Set(f.map((o) => o.declarationId)).size === 1, 'f(n) names the parameter f');
    // a method called inside its class without a receiver, and with one, name the method
    const twice = occurrence(d, 'twice');
    assert.equal(twice.length, 3);
    assert.ok(twice.every((o) => o.declarationId) && new Set(twice.map((o) => o.declarationId)).size === 1, 'twice(n) names the method twice');
    // find-references on the method: its declaration, the call inside the class and the call with a receiver
    const refs = (await s.rpc('query/references', { uri: d.uri, offset: twice[0].range.start })).result.value;
    assert.equal(refs.length, 3);
    await s.close();
}

// The language's built-in types and members have no declaration in any program: the editor names them from the documentation module
// stdlib/abla/builtins/declarations.ab, which the service adds to the answer as a document that is never typed. Go-to-definition opens it, hover shows
// the declaration, and a program's own declaration of the same name wins.
async function builtins(mode) {
    const main = [
        'class Cell(val v: int)',
        'fun main: int {',
        '    val xs: array<int> = []',
        '    xs.append(1)',
        '    val m: Map<string, int> = Map()',
        '    m.set("a", 1)',
        '    val c = Cell(2)',
        '    val s = "abc"',
        '    val t = s.slice(0, 1)',
        '    val n = xs.size + m.size + s.size + c.v',
        '    if (m.has("a")) return n',
        '    return 0',
        '}',
        '',
    ].join('\n');
    const p = fixture(`builtins-${mode}`, { 'main.ab': main });
    const s = await start(p, { mode });
    const a = await s.analyze();
    noErrors(a);
    const d = doc(a, path.join(p, 'main.ab'));
    const stubUri = a.documents.map((x) => x.uri).find((u) => u.endsWith('/stdlib/abla/builtins/declarations.ab'));
    assert.ok(stubUri, 'the built-in documentation module is a document of the answer');
    const stub = a.documents.find((x) => x.uri === stubUri);
    const stubSymbol = (name, container) => stub.symbols.find((x) => x.name === name && (container === undefined || x.containerId?.endsWith(container) || x.id.includes(container)));
    const at = (name, nth = 0) => occurrence(d, name)[nth];
    const named = (o, expectName) => {
        assert.ok(o, `an occurrence of ${expectName}`);
        assert.ok(o.declarationId, `${expectName} names a declaration`);
        const symbol = stub.symbols.find((x) => x.id === o.declarationId);
        assert.ok(symbol, `${expectName} names a declaration of the documentation module (${o.declarationId})`);
        assert.equal(symbol.name, expectName);
        return symbol;
    };
    // members: the method call, the property and the call through a nullable result
    named(at('append'), 'append');
    named(at('set'), 'set');
    named(at('has'), 'has');
    named(at('slice'), 'slice');
    const sizes = occurrence(d, 'size');
    assert.equal(sizes.length, 3);
    for (const o of sizes) named(o, 'size');
    // types: written as types, as constructors and as the receiver's declared types
    for (const name of ['array', 'Map', 'string', 'int']) {
        const uses = occurrence(d, name).filter((o) => d.text[o.range.start - 1] !== '.');
        assert.ok(uses.length > 0, `a use of ${name}`);
        for (const o of uses) named(o, name);
    }
    // the program's own class named like a built-in is its own (Cell has no built-in declaration here: the program's wins)
    const own = d.symbols.find((x) => x.name === 'Cell');
    assert.ok(own);
    for (const o of occurrence(d, 'Cell').filter((x) => d.text[x.range.start - 1] !== '.')) assert.equal(o.declarationId, own.id, 'the program declares Cell');
    // go-to-definition and hover on a built-in go to the documentation module
    const params = (o) => ({ uri: d.uri, offset: o.range.start });
    const definition = (await s.rpc('query/definition', params(at('append')))).result.value;
    assert.equal(definition.uri, stubUri);
    const hover = (await s.rpc('query/hover', params(at('append')))).result.value;
    assert.equal(hover.symbol.name, 'append');
    assert.equal(hover.symbol.uri, stubUri);
    // find-references on the declaration in the documentation module finds the use in the program
    const references = (await s.rpc('query/references', { uri: stubUri, offset: stubSymbol('append').selectionRange.start })).result.value;
    assert.ok(references.some((r) => r.uri === d.uri), 'the call of append is a reference of the built-in append');
    await s.close();
}

// A field assigned inside its class (`count = count + 1`, `this.total = 2`) and through another object (`other.count = 3`) names the field, as a read of it does.
async function fieldAssign(mode) {
    const main = [
        'class Counter(var count: int, var total: int) {',
        '    fun bump(var other: Counter): int {',
        '        count = count + 1',
        '        this.total = 2',
        '        other.count = 3',
        '        return count + total',
        '    }',
        '}',
        'fun main: int {',
        '    val c = Counter(0, 0)',
        '    c.count = 5',
        '    val d = Counter(1, 1)',
        '    return c.bump(d)',
        '}',
        '',
    ].join('\n');
    const p = fixture(`field-assign-${mode}`, { 'main.ab': main });
    const s = await start(p, { mode });
    const a = await s.analyze();
    noErrors(a);
    const d = doc(a, path.join(p, 'main.ab'));
    const field = (name) => d.symbols.find((x) => x.name === name && /field/.test(x.id));
    for (const name of ['count', 'total']) {
        const id = field(name).id;
        const uses = occurrence(d, name);
        assert.ok(uses.length >= 3, `uses of ${name}`);
        for (const o of uses) assert.equal(o.declarationId, id, `every use of the field ${name} names it (${d.text.slice(0, o.range.start).split('\n').length}: ${o.declarationId})`);
    }
    // find-references on the field: its parameter, the assignments and the reads
    const refs = (await s.rpc('query/references', { uri: d.uri, offset: occurrence(d, 'count')[0].range.start })).result.value;
    assert.equal(refs.length, occurrence(d, 'count').length);
    await s.close();
}

// A symbol carries the comment above its declaration as `documentation`: a `/** ... */` block, or a run of `//` lines with no blank line
// between it and the declaration (annotation lines in between do not end it); constructor fields too.
async function documentation(mode) {
    const main = [
        '/** Adds one.',
        ' * More text.',
        ' */',
        'fun inc(n: int): int = n + 1',
        '',
        '// A line comment',
        '// over two lines.',
        'fun dec(n: int): int = n - 1',
        '',
        '// separated by a blank line',
        '',
        'fun plain(): int = 0',
        '',
        '/** A class. */',
        'class Box(',
        '    /** The held value. */',
        '    val value: int,',
        '    val bare: int',
        ') {',
        '    /** Doubles. */',
        '    fun twice(): int = value * 2',
        '    fun same(): int = value',
        '}',
        '',
        '/** Annotated. */',
        '@noinline',
        'fun annotated(): int = 1',
        '',
        '/** Parameter example. */',
        'fun withDocs(',
        '    /** The first operand. */',
        '    left: int,',
        '    // The second operand.',
        '    right: int = 2',
        '): int = left + right',
        '',
        'fun <T> mapArgs(items: Map<string, array<T>>, transform: (T) -> T): int = 0',
        '',
        '/** A private helper. */',
        'private fun secret(): int = 3',
        '',
        'fun main: int = inc(1) + dec(2) + plain() + annotated() + Box(1, 2).twice()',
        '',
    ].join('\n');
    const p = fixture(`documentation-${mode}`, { 'main.ab': main });
    const s = await start(p, { mode });
    const a = await s.analyze();
    noErrors(a);
    const d = doc(a, path.join(p, 'main.ab'));
    const docOf = (name) => d.symbols.find((x) => x.name === name)?.documentation;
    assert.equal(docOf('inc'), 'Adds one.\nMore text.');
    assert.equal(docOf('dec'), 'A line comment\nover two lines.');
    assert.equal(docOf('plain'), undefined, 'a blank line ends the comment');
    assert.equal(docOf('Box'), 'A class.');
    assert.equal(docOf('value'), 'The held value.');
    assert.equal(docOf('bare'), undefined);
    assert.equal(docOf('twice'), 'Doubles.');
    assert.equal(docOf('same'), undefined);
    assert.equal(docOf('annotated'), 'Annotated.');
    assert.equal(docOf('main'), undefined);
    const symbolOf = (name) => d.symbols.find((x) => x.name === name);
    assert.equal(symbolOf('inc').signature, 'fun inc(n: int): int');
    assert.equal(symbolOf('secret').signature, 'private fun secret(): int');
    assert.equal(docOf('secret'), 'A private helper.');
    assert.equal(symbolOf('twice').signature, 'fun twice(): int');
    assert.equal(symbolOf('annotated').signature, '@noinline\nfun annotated(): int');
    assert.equal(symbolOf('withDocs').signature, [
        'fun withDocs(',
        '    /** The first operand. */',
        '    left: int,',
        '    // The second operand.',
        '    right: int = 2',
        '): int',
    ].join('\n'));
    assert.deepEqual(symbolOf('withDocs').parameters, [
        { name: 'left', label: 'left: int', documentation: 'The first operand.' },
        { name: 'right', label: 'right: int = 2', documentation: 'The second operand.' },
    ]);
    assert.equal(docOf('left'), 'The first operand.');
    assert.equal(docOf('right'), 'The second operand.');
    assert.equal(symbolOf('Box').parameters[0].label, 'val value: int');
    assert.equal(symbolOf('Box').parameters[0].documentation, 'The held value.');
    assert.deepEqual(symbolOf('mapArgs').parameters, [
        { name: 'items', label: 'items: Map<string, array<T>>' },
        { name: 'transform', label: 'transform: (T) -> T' },
    ]);
    // the standard library's and the built-ins' comments come with their declarations
    const stub = a.documents.find((x) => x.uri.endsWith('/stdlib/abla/builtins/declarations.ab'));
    assert.equal(stub.symbols.find((x) => x.name === 'append').documentation, 'Adds `value` at the end.');
    assert.equal(stub.symbols.find((x) => x.name === 'size' && x.kind === 'property').documentation.length > 0, true);
    // hover returns the symbol, so it carries the documentation
    const call = d.occurrences.find((o) => o.name === 'inc' && o.declarationId);
    const hover = (await s.rpc('query/hover', { uri: d.uri, offset: call.range.start })).result.value;
    assert.equal(hover.symbol.documentation, 'Adds one.\nMore text.');
    assert.equal(hover.symbol.signature, 'fun inc(n: int): int');
    assert.deepEqual(hover.symbol.parameters, [{ name: 'n', label: 'n: int' }]);
    assert.equal('documentationSpan' in hover.symbol, false);
    assert.equal('documentationSpan' in symbolOf('withDocs').parameters[0], false);

    // A diagnostics-only response projection still refreshes the text used by hover.
    // Exercise shifted UTF-8 offsets and an overlay whose docs differ from disk.
    const edited = '// café 😀\n\n' + main.replace('Adds one.', 'Adds one (overlay).');
    await s.rpc('document/open', { uri: d.uri, version: 1, text: edited });
    const projected = (await s.rpc('analyze', { fields: ['diagnostics'] })).result;
    assert.equal('symbols' in doc(projected, path.join(p, 'main.ab')), false);
    const offset = bytes(edited.slice(0, edited.indexOf('inc(1)')));
    const query = { uri: d.uri, offset, revision: projected.revision };
    const editedHover = (await s.rpc('query/hover', query)).result.value;
    assert.equal(editedHover.symbol.documentation, 'Adds one (overlay).\nMore text.');
    const symbolsOnly = (await s.rpc('analyze', { fields: ['symbols'] })).result;
    const editedSymbols = doc(symbolsOnly, path.join(p, 'main.ab')).symbols;
    assert.equal(editedSymbols.find((symbol) => symbol.name === 'inc').documentation,
        editedHover.symbol.documentation);
    await s.rpc('document/close', { uri: d.uri });
    const restored = (await s.rpc('query/hover', { uri: d.uri, offset: call.range.start })).result.value;
    assert.equal(restored.symbol.documentation, hover.symbol.documentation);
    await s.close();
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

// A call with named, defaulted or mixed arguments is the call it names (#814): the compiler's own temporaries
// (`__abla_named_<offset>_<n>`, ...) are not in the source and must not take its span. One of them once did when its
// name was as long as the call's, so the callee lost its declaration (and go-to-definition and hover with it): the
// callees here have every name length from 10 to 30, in named, defaulted and mixed calls and in a constructor's.
async function namedCalls() {
    const names = [];
    for (let length = 10; length <= 30; length++) names.push('f' + 'x'.repeat(length - 1));
    const dep = [
        'fun box(width: int, height: int = 2, label: string = "x"): int = width * height',
        'class Point(val x: int, val y: int = 0)',
        ...names.map((name) => `fun ${name}(): int = 3`),
        '',
    ].join('\n');
    const lines = ['import "dep.ab"', 'fun main: int {'];
    names.forEach((name, index) => {
        lines.push(`    val named${index} = box(height = 1, width = ${name}())`);
        lines.push(`    val defaulted${index} = box(${name}())`);
        lines.push(`    val mixed${index} = box(${name}(), label = "y")`);
        lines.push(`    val point${index} = Point(y = ${name}(), x = 1)`);
    });
    lines.push('    0', '}', '');
    const p = fixture('named-calls', { 'main.ab': lines.join('\n'), 'dep.ab': dep });
    const s = await start(p);
    const a = await s.analyze();
    noErrors(a);
    const document = doc(a, path.join(p, 'main.ab'));
    const dependency = doc(a, path.join(p, 'dep.ab'));
    assert.deepEqual(document.occurrences.filter((o) => o.name.startsWith('__abla_')), []);
    const check = async (name, symbol, count) => {
        const found = occurrence(document, name);
        assert.equal(found.length, count, `${name}: occurrences`);
        for (const call of found) {
            assert.equal(call.declarationId, symbol.id, `${name} at ${call.range.start}: declarationId`);
            assert.ok(call.type, `${name} at ${call.range.start}: type`);
            const params = { uri: uri(path.join(p, 'main.ab')), offset: call.range.start, revision: a.revision };
            const definition = (await s.rpc('query/definition', params)).result;
            assert.equal(definition.value.uri, uri(path.join(p, 'dep.ab')), `${name} at ${call.range.start}: definition`);
            const hover = (await s.rpc('query/hover', params)).result;
            assert.ok(hover.value.type, `${name} at ${call.range.start}: hover`);
        }
    };
    await check('box', dependency.symbols.find((x) => x.name === 'box'), names.length * 3);
    for (const name of names) await check(name, dependency.symbols.find((x) => x.name === name), 4);
    await s.close();
}

// A long-lived service keeps work between analyses; its answer must still be the answer of a service that has never seen the
// project before, whatever the edits that came in between. Each step is compared byte for byte (the revision, a counter of
// the session's own, aside) with a fresh service given the same open documents.
async function editSequence(mode = 'graph-v1') {
    const files = {
        'main.ab': 'import "util.ab"\nimport "model.ab"\nfun main: int {\n    val m = Model(1)\n    scale(m.value) + extra()\n}\n',
        'util.ab': 'import "model.ab"\nfun scale(value: int): int = value * 2\nfun extra(): int = helper(3)\nprivate fun helper(n: int): int = n + 1\n',
        'model.ab': 'class Model(val value: int) {\n    fun twice(): int = value * 2\n}\n',
    };
    const p = fixture(`edit-sequence-${mode}`, files);
    const at = (file) => path.join(p, file);
    const open = new Map();
    const comparable = (snapshot) => JSON.stringify({ ...snapshot, revision: 0 });
    const cold = async () => {
        const fresh = await start(p, { mode });
        for (const [file, { version, text }] of open) {
            assert.ok(!('error' in await fresh.rpc('document/open', { uri: uri(at(file)), version, text })));
        }
        const answer = await fresh.analyze();
        await fresh.close();
        return comparable(answer);
    };
    const s = await start(p, { mode });
    let version = 0;
    const edit = async (file, text) => {
        version += 1;
        const method = open.has(file) ? 'document/change' : 'document/open';
        assert.ok(!('error' in await s.rpc(method, { uri: uri(at(file)), version, text })), `${method} ${file}`);
        open.set(file, { version, text });
    };
    const close = async (file) => {
        await s.rpc('document/close', { uri: uri(at(file)) });
        open.delete(file);
    };
    const check = async (label) => {
        const incremental = comparable(await s.analyze());
        assert.equal(incremental, await cold(), `${label}: the edited service's answer differs from a fresh service's`);
        const again = comparable(await s.analyze());
        assert.equal(again, incremental, `${label}: a second analysis of the same state differs`);
    };
    await check('before any edit');
    await edit('util.ab', files['util.ab'].replace('value * 2', 'value * 3'));
    await check('a body edit');
    await edit('util.ab', files['util.ab'].replace('value * 2', 'value * 3').replace('(): int = helper', '(): int =\n    helper'));
    await check('a whitespace edit that moves ranges');
    await edit('model.ab', files['model.ab'].replace('Model(val value: int)', 'Model(val value: string)'));
    await check('a type change seen from two files');
    await edit('model.ab', files['model.ab']);
    await check('the type change reverted');
    await edit('main.ab', files['main.ab'].replace('scale(m.value)', 'scale(m.missing)'));
    await check('an error introduced');
    await edit('main.ab', files['main.ab'].replace('scale(m.value)', 'scale(m.twice())'));
    await check('the error fixed another way');
    await edit('util.ab', '// an edit before every range\n' + files['util.ab']);
    await check('a comment added at the top');
    await edit('main.ab', files['main.ab'].replace('import "model.ab"\n', ''));
    await check('an import removed');
    await edit('main.ab', files['main.ab']);
    await check('the import back');
    await edit('model.ab', files['model.ab'] + 'fun more(): int = 1\n');
    await check('a declaration added');
    await close('util.ab');
    await check('an overlay closed');
    fs.writeFileSync(at('model.ab'), files['model.ab'].replace('value * 2', 'value * 5'));
    await close('model.ab');
    await check('a file changed on disk');
    fs.writeFileSync(at('model.ab'), files['model.ab']);
    await s.close();
}

// graph-v2 names a declaration by its module, its container and its name (and a function by its parameter types), not by its offset: an
// edit that moves other declarations leaves their ids alone, and every id a document's occurrences name is one of a symbol's.
async function stableIds() {
    const model = [
        'class Model(val value: int, val label: string) {',
        '    fun twice(): int = value * 2',
        '    fun twice(factor: int): int = value * factor',
        '}',
        '',
    ].join('\n');
    const util = [
        'import "model.ab"',
        'fun scale(value: int): int {',
        '    val doubled = value * 2',
        '    val doubled2 = doubled + 1',
        '    return doubled2',
        '}',
        'fun scale(value: string): string = value',
        'fun total(items: array<int>): int {',
        '    var sum = 0',
        '    for (item in items) sum += item',
        '    val add = { a: int -> a + sum }',
        '    return add(1)',
        '}',
        'fun twice(m: Model): int = m.twice() + m.twice(2)',
        '',
    ].join('\n');
    const main = 'import "util.ab"\nimport "model.ab"\nfun main: int {\n    val m = Model(1, "x")\n    scale(m.value) + total([1, 2]) + twice(m)\n}\n';
    const p = fixture('stable-ids', { 'main.ab': main, 'util.ab': util, 'model.ab': model });
    const ids = (snapshot, file) => doc(snapshot, path.join(p, file)).symbols.map((x) => x.id);
    const s = await start(p, { mode: 'graph-v2' });
    const a = await s.analyze();
    noErrors(a);
    // Every symbol id is unique across the graph, every id an occurrence names is a symbol's, and none carries an offset.
    const all = new Set();
    for (const d of a.documents) for (const symbol of d.symbols) {
        assert.ok(!all.has(symbol.id), `duplicate id ${symbol.id}`);
        all.add(symbol.id);
        assert.ok(symbol.id.startsWith('abla:'), symbol.id);
        assert.ok(!/:\d+:/.test(symbol.id), `an offset in ${symbol.id}`);
    }
    for (const d of a.documents) for (const symbol of d.symbols) if ('containerId' in symbol) assert.ok(all.has(symbol.containerId), `unknown container of ${symbol.id}`);
    let named = 0;
    for (const d of a.documents) for (const o of d.occurrences) if (o.declarationId) {
        named += 1;
        assert.ok(all.has(o.declarationId), `${o.name} names ${o.declarationId}, which no symbol has`);
    }
    assert.ok(named > 20, 'few occurrences name a declaration');
    const modelPath = path.join(p, 'model.ab');
    const utilIds = ids(a, 'util.ab');
    const twice = ids(a, 'model.ab').filter((id) => /\.twice\([^)]*\)$/.test(id));
    assert.equal(twice.length, 2, 'the two overloads of twice have two ids');
    assert.notEqual(twice[0], twice[1]);
    assert.ok(utilIds.filter((id) => /#scale\([^)]*\)$/.test(id)).length === 2, 'the overloads of scale differ');
    // Locals, a loop variable and a lambda parameter are named by their declaration and their name.
    for (const part of ['/param:value', '/local:doubled', '/local:doubled2', '/for:item', '/local:sum', '/lambda:a']) {
        assert.ok(utilIds.some((id) => id.includes(part)), `no symbol with ${part}: ${utilIds.join(' ')}`);
    }
    // A name used from another file resolves to the declaration's id, and the queries answer with it.
    const mainDoc = doc(a, path.join(p, 'main.ab'));
    const scale = mainDoc.occurrences.find((o) => o.name === 'scale');
    assert.ok(scale.declarationId.includes('util.ab#scale('), scale.declarationId);
    const query = (method, offset) => s.rpc(method, { uri: uri(path.join(p, 'main.ab')), offset, revision: a.revision });
    assert.equal((await query('query/definition', scale.range.start)).result.value.id, scale.declarationId);
    assert.equal((await query('query/hover', scale.range.start)).result.value.symbol.id, scale.declarationId);
    const refs = (await query('query/references', scale.range.start)).result.value;
    assert.ok(refs.some((r) => r.uri === uri(path.join(p, 'main.ab'))));
    // Edits that move offsets keep every id: a comment on top of each file, an added declaration before the others, a longer body.
    const before = new Map(a.documents.map((d) => [d.uri, d.symbols.map((x) => x.id)]));
    const open = async (file, text, version) => assert.ok(!('error' in await s.rpc('document/open', { uri: uri(path.join(p, file)), version, text })));
    await open('util.ab', '// a comment before every offset\n' + util.replace('    val doubled = value * 2\n', '    val unused = 1\n    val doubled = value * 2\n'), 1);
    await open('model.ab', 'fun added(): int = 1\n' + model, 1);
    const b = await s.analyze();
    noErrors(b);
    for (const [uriText, was] of before) {
        const now = doc(b, fileURLToPath(uriText)).symbols.map((x) => x.id);
        for (const id of was) assert.ok(now.includes(id), `${id} is not an id after the edit`);
    }
    assert.ok(ids(b, 'util.ab').some((id) => id.includes('/local:unused')));
    // The occurrences in main.ab are those of before (nothing in it changed), so its whole export is.
    assert.equal(JSON.stringify(doc(b, path.join(p, 'main.ab')).occurrences.map((o) => o.declarationId)),
        JSON.stringify(mainDoc.occurrences.map((o) => o.declarationId)), 'main.ab names other ids after an edit that moved offsets elsewhere');
    // A graph-v1 service still names declarations by offset.
    const legacy = await start(p);
    const v1 = await legacy.analyze();
    assert.ok(ids(v1, 'util.ab').every((id) => /:\d+:/.test(id)), 'graph-v1 ids are offset-based');
    await legacy.close();
    await s.close();
}

// analyze with `since` (graph-v2) answers with what differs from the revision the client holds; applying it to the client's copy gives
// the full answer, byte for byte, whatever the edits between (a fresh service's full answer is the reference).
async function since() {
    const files = {
        'main.ab': 'import "util.ab"\nimport "model.ab"\nfun main: int {\n    val m = Model(1)\n    scale(m.value) + extra()\n}\n',
        'util.ab': 'import "model.ab"\nfun scale(value: int): int = value * 2\nfun extra(): int = helper(3)\nprivate fun helper(n: int): int = n + 1\n',
        'model.ab': 'class Model(val value: int) {\n    fun twice(): int = value * 2\n}\n',
        'lone.ab': 'fun lonely(): int = 7\n',
    };
    const p = fixture('since', files);
    const at = (file) => path.join(p, file);
    const s = await start(p, { mode: 'graph-v2' });
    const open = new Map();
    let version = 0;
    const edit = async (file, text) => {
        version += 1;
        const method = open.has(file) ? 'document/change' : 'document/open';
        assert.ok(!('error' in await s.rpc(method, { uri: uri(at(file)), version, text })));
        open.set(file, { version, text });
    };
    const full = async () => {
        const fresh = await start(p, { mode: 'graph-v2' });
        for (const [file, { version: v, text }] of open) await fresh.rpc('document/open', { uri: uri(at(file)), version: v, text });
        const answer = await fresh.analyze();
        await fresh.close();
        return answer;
    };
    // The client's copy: documents by uri, brought up to date by each reply.
    const held = new Map();
    const apply = (reply) => {
        if (reply.full) held.clear();
        for (const uriText of reply.removed ?? []) held.delete(uriText);
        for (const d of reply.documents) held.set(d.uri, d);
        for (const uriText of reply.unchanged ?? []) assert.ok(held.has(uriText), `unchanged ${uriText} is not held`);
    };
    const check = async (label, expectChanged) => {
        const reply = (await s.rpc('analyze', { since: revision })).result;
        revision = reply.revision;
        assert.equal(reply.since !== undefined, true);
        const before = held.size;
        apply(reply);
        const reference = await full();
        assert.equal(held.size, reference.documents.length, `${label}: documents held`);
        for (const d of reference.documents) assert.equal(JSON.stringify(held.get(d.uri)), JSON.stringify(d), `${label}: ${d.uri}`);
        if (expectChanged !== undefined) assert.deepEqual(reply.documents.map((d) => path.basename(fileURLToPath(d.uri))).sort(), expectChanged, `${label}: changed documents`);
        return reply;
    };
    // The first analysis: no since, the full answer, and a since the service does not hold gets the full answer again.
    const first = await s.analyze();
    let revision = first.revision;
    assert.equal(first.full, undefined);
    for (const d of first.documents) held.set(d.uri, d);
    const lost = (await s.rpc('analyze', { since: 'no-such-revision' })).result;
    assert.equal(lost.full, true);
    assert.equal(lost.documents.length, first.documents.length);
    // Nothing changed: no documents.
    const same = await check('nothing changed', []);
    assert.equal(same.full, false);
    assert.equal(same.unchanged.length, first.documents.length);
    // A body edit that moves offsets in util.ab: only util.ab changes (ids are stable, so main.ab and model.ab keep their exports).
    await edit('util.ab', files['util.ab'].replace('value * 2', 'value * 2 + 0'));
    await check('a body edit', ['util.ab']);
    // A comment on top of model.ab: only model.ab.
    await edit('model.ab', '// on top\n' + files['model.ab']);
    await check('a comment on top', ['model.ab']);
    // A signature change: the file and its callers.
    await edit('util.ab', files['util.ab'].replace('scale(value: int)', 'scale(value: int, extra: int)').replace('value * 2', 'value * extra'));
    const signature = await check('a signature change');
    assert.ok(signature.documents.some((d) => d.uri === uri(at('util.ab'))));
    assert.ok(signature.documents.some((d) => d.uri === uri(at('main.ab'))), 'the caller changes with the signature');
    // An unrelated file never changes.
    assert.ok(!signature.documents.some((d) => d.uri === uri(at('lone.ab'))));
    // An error and its fix, a change on disk, a file that leaves the graph.
    await edit('main.ab', files['main.ab'].replace('scale(m.value)', 'scale(m.missing)'));
    await check('an error');
    await edit('main.ab', files['main.ab'].replace('import "model.ab"\n', ''));
    await edit('main.ab', 'import "util.ab"\nfun main: int = extra()\n');
    await edit('util.ab', 'fun extra(): int = 3\nprivate fun helper(n: int): int = n + 1\n');
    const dropped = await check('model.ab leaves the graph');
    assert.ok(dropped.removed.includes(uri(at('model.ab'))), 'the file that left the graph is listed in removed');
    // since is for graph-v2 only, and a non-string is refused; fields projects the delta.
    assert.equal(code(await s.rpc('analyze', { since: 5 })), 'invalid_params');
    const projected = (await s.rpc('analyze', { since: revision, fields: ['diagnostics'] })).result;
    assert.equal(projected.full, false);
    assert.ok(projected.documents.every((d) => !('occurrences' in d)));
    await s.close();
    const legacy = await start(p);
    assert.equal(code(await legacy.rpc('analyze', { since: '1' })), 'invalid_params');
    await legacy.close();
}

// A subparser of the standard library ($json) is expanded by the analysis, so the value is typed (a bad member is an error, a good one is
// not); a subparser a program registers itself is not run in the editor: one soft note at its site and an opaque value, nothing cascading.
async function subparsers() {
    const json = fixture('subparser-stdlib', { 'main.ab': 'import "abla/io"\nimport "abla/json"\n\nfun main: int {\n    val count = 3\n    val doc = $json {"n": count, "name": "x"}\n    println(doc.get("name").asString())\n    0\n}\n' });
    let s = await start(json, { mode: 'graph-v2' });
    const used = await s.analyze();
    noErrors(used);
    assert.equal(used.complete, true, 'a stdlib subparser use leaves nothing pending: ' + JSON.stringify(used.pending));
    await s.rpc('document/open', { uri: uri(path.join(json, 'main.ab')), version: 1, text: 'import "abla/io"\nimport "abla/json"\n\nfun main: int {\n    val doc = $json {"n": 1}\n    println(doc.get("name").nosuch())\n    0\n}\n' });
    const bad = errors(await s.analyze());
    assert.equal(bad.length, 1, JSON.stringify(bad));
    assert.ok(bad[0][2].includes('method.unknown:Json.nosuch'), bad[0][2]);
    await s.close();
    const imported = fixture('subparser-import-only', { 'main.ab': 'import "abla/io"\nimport "abla/json"\n\nfun main: int {\n    println("x")\n    0\n}\n' });
    s = await start(imported, { mode: 'graph-v2' });
    const only = await s.analyze();
    noErrors(only);
    assert.equal(only.complete, true, 'importing abla/json leaves nothing pending: ' + JSON.stringify(only.pending));
    await s.close();
    const own = fixture('subparser-user', { 'main.ab': [
        'import "abla/io"', 'import "abla/text"', 'import "abla/compiler/parser"', '',
        'compile fun parseShout(cursor: ParserCursor): SyntaxExpression {',
        '    parserRawExpect(cursor, "[")', '    val text = parserRawTakeUntil(cursor, "]")', '    parserRawExpect(cursor, "]")',
        '    syntaxString(text.uppercase() + "!")', '}', '#compilerRegisterSubparser("shout", parseShout)', '',
        'fun main: int {', '    val s = $shout[hello]', '    println(s.size)', '    val t = s.foo.bar(1, 2)[3]', '    println(t)', '    val n: int = s', '    n + 1', '}', ''].join('\n') });
    s = await start(own, { mode: 'graph-v2' });
    const own_result = await s.analyze();
    const notes = errors(own_result);
    assert.equal(own_result.complete, true, 'a registration of the program is not a pending evaluation: ' + JSON.stringify(own_result.pending));
    assert.equal(notes.length, 1, JSON.stringify(notes));
    assert.equal(notes[0][1], 'W_SUBPARSER_NOT_EXPANDED');
    await s.close();
}

async function sqlSubparsers() {
    const project = fixture('sql-stdlib', { 'main.ab': 'import "abla/sql"\nfun main: int { val q = $sql("SELECT ${1}::integer"); q.parameters.size }\n' });
    const s = await start(project, { mode: 'graph-v2' });
    noErrors(await s.analyze());
    await s.rpc('document/open', { uri: uri(path.join(project, 'main.ab')), version: 1,
        text: 'import "abla/sql"\nfun main: int { val q = $sql("SELECT FROM t"); 0 }\n' });
    let notes = errors(await s.analyze());
    assert.ok(notes.some(n => n[1] === 'E_SUBPARSER_FAILURE' && n[2].includes('SQL')), JSON.stringify(notes));
    await s.rpc('document/change', { uri: uri(path.join(project, 'main.ab')), version: 2,
        text: 'import "abla/sql"\nfun main: int { val q = $sql("SELECT ${true}::uuid"); 0 }\n' });
    notes = errors(await s.analyze());
    assert.ok(notes.length > 0 && !notes.some(n => n[1] === 'W_SUBPARSER_NOT_EXPANDED'), JSON.stringify(notes));
    await s.rpc('document/change', { uri: uri(path.join(project, 'main.ab')), version: 3,
        text: 'import "abla/sql"\nfun main: int {\n  val q = $sql { SELECT $json$ } " $json$ AS body, 1::integer }\n  q.parameters.size\n}\n' });
    noErrors(await s.analyze());
    await s.rpc('document/change', { uri: uri(path.join(project, 'main.ab')), version: 4,
        text: 'import "abla/sql"\nfun main: int { val q = $sql { SELECT FROM t }; 0 }\n' });
    notes = errors(await s.analyze());
    assert.ok(notes.some(n => n[1] === 'E_SUBPARSER_FAILURE' && n[2].includes('SQL')), JSON.stringify(notes));
    await s.close();
}

// refactor/validate answers with the prospective snapshot WITH its occurrences (a client that renames a symbol the edit moved needs them):
// the snapshot the service holds has them null, an answer carries them made.
async function validateOccurrences() {
    const p = fixture('validate-occurrences', { 'main.ab': 'fun helper(x: int): int = x + 1\n\nfun main: int = helper(2)\n' });
    const s = await start(p, { mode: 'graph-v2' });
    const a = await s.analyze();
    const main = doc(a, path.join(p, 'main.ab'));
    const v = (await s.rpc('refactor/validate', { baseRevision: a.revision, edits: [{ uri: main.uri, start: 0, end: 0, newText: '// note\n' }], invariants: ['no-new-errors'] })).result;
    assert.equal(v.valid, true, v.reason);
    const prospective = doc(v.snapshot, path.join(p, 'main.ab'));
    assert.ok(Array.isArray(prospective.occurrences) && prospective.occurrences.length > 0, 'the prospective document carries its occurrences');
    await s.close();
}

async function typedRegexDefinitions() {
    const text = String.raw`// λ 😀
import "abla/regex"
import "abla/array"
import "abla/process/exit"
import "other.ab"

fun main: int {
    val matcher = $regex("\\dé\u{1F600}(?<\x79ear>[0-9]+)(?:-(?<month>[0-9]+))?")
    val local = matcher.find("1é😀2026") ?? panic("local")
    val twin = $regex("(?<year>q)").find("q") ?? panic("twin")
    val remote = otherCapture() ?? panic("remote")
    val raw = $regex("""
        é
        (?<day>z)
        """
    ).find("é\nz") ?? panic("raw")
    local.year.size + (local.month ?? "").size + twin.year.size + remote.year.size + raw.day.size
}
`;
    const otherText = 'import "abla/regex"\nfun otherCapture() = $regex("(?<year>z)").find("z")\n';
    const project = fixture('typed-regex-definitions', { 'main.ab': text, 'other.ab': otherText });
    const mainPath = path.join(project, 'main.ab');
    const otherPath = path.join(project, 'other.ab');
    const s = await start(project, { mode: 'graph-v2' });
    const assertDefinition = async (snapshot, source, use, destination, name, spelling, type) => {
        const useAt = source.indexOf(use);
        assert.ok(useAt >= 0);
        const offset = bytes(source.slice(0, useAt + use.indexOf('.') + 1));
        const location = { uri: uri(mainPath), offset, revision: snapshot.revision };
        const definition = (await s.rpc('query/definition', location)).result.value;
        assert.ok(definition, use + ' needs a definition');
        const targetDoc = doc(snapshot, destination);
        const startAt = targetDoc.text.indexOf(spelling);
        assert.ok(startAt >= 0);
        const start = bytes(targetDoc.text.slice(0, startAt));
        const expected = { start, end: start + bytes(spelling) };
        assert.equal(definition.uri, targetDoc.uri, use);
        assert.equal(definition.name, name, use);
        assert.equal(definition.kind, 'property', use);
        assert.deepEqual(definition.selectionRange, expected, use);
        assert.deepEqual(definition.range, expected, use);
        assert.equal((await s.rpc('query/hover', location)).result.value.type, type, use);
        assert.ok(!targetDoc.symbols.some(symbol => symbol.id === definition.id), 'navigation-only target');
        return definition.id;
    };
    try {
        const initial = await s.analyze();
        noErrors(initial);
        assert.equal(initial.complete, true, JSON.stringify(initial.pending));
        const local = await assertDefinition(initial, text, 'local.year', mainPath, 'year', String.raw`\x79ear`, 'string');
        const twin = await assertDefinition(initial, text, 'twin.year', mainPath, 'year', 'year', 'string');
        const remote = await assertDefinition(initial, text, 'remote.year', otherPath, 'year', 'year', 'string');
        assert.notEqual(local, twin, 'same spelling in one file is distinct');
        assert.notEqual(twin, remote, 'same spelling across files is distinct');
        assert.notEqual(local, remote, 'same spelling across literals is distinct');
        await assertDefinition(initial, text, 'local.month', mainPath, 'month', 'month', 'nullable:string');
        await assertDefinition(initial, text, 'raw.day', mainPath, 'day', 'day', 'string');
        const shifted = '// moved 😀\n' + text;
        await s.rpc('document/open', { uri: uri(mainPath), version: 1, text: shifted });
        const edited = await s.analyze();
        noErrors(edited);
        const moved = await assertDefinition(edited, shifted, 'local.year', mainPath, 'year', String.raw`\x79ear`, 'string');
        assert.equal(moved, local, 'a prefix-only overlay moves the range while preserving the field id');
    } finally {
        await s.close();
    }
}

async function incrementalBodyReplay() {
    const original = 'fun answer: int {\n    42\n}\nfun afterAnswer: int = 7\n';
    const main = 'import "dep.ab"\nfun main: int = answer()\n';
    const p = fixture('body-replay', { 'main.ab': main, 'dep.ab': original });
    const env = { ...process.env, ABLA_ANALYSIS_INCREMENTAL_TRACE: '1', ABLA_ANALYSIS_CHECK: '1' };
    delete env.ABLA_ANALYSIS_INCREMENTAL_TYPING;
    const replay = await start(p, { mode: 'graph-v2', env, log: 'replay.stderr' });
    const full = await start(p, { mode: 'graph-v2',
        env: { ...env, ABLA_ANALYSIS_INCREMENTAL_TYPING: '0', ABLA_ANALYSIS_CHECK: '0' }, log: 'full.stderr' });
    const sessions = [replay, full];
    let revision;
    const check = async (label) => {
        const [a, b] = await Promise.all(sessions.map(session => session.analyze()));
        assert.deepEqual(a, b, label);
        if (revision !== undefined) {
            const [actual, expected] = await Promise.all(sessions.map(s => s.rpc('analyze', { since: revision })));
            assert.deepEqual(actual, expected, label + ' delta');
        }
        revision = a.revision;
        const editor = { uri: uri(path.join(p, 'main.ab')), offset: bytes(main.slice(0, main.indexOf('answer()'))), revision };
        for (const method of ['query/definition', 'query/hover', 'query/references']) {
            const [actual, expected] = await Promise.all(sessions.map(s => s.rpc(method, editor)));
            assert.deepEqual(actual, expected, label + ' ' + method);
        }
        return fs.readFileSync(replay.log, 'utf8').split('\n').filter(line => line.includes('replayed a type-inert')).length;
    };
    let version = 0;
    const edit = async (text) => {
        version++;
        const params = { uri: uri(path.join(p, 'dep.ab')), version, text };
        const method = version === 1 ? 'document/open' : 'document/change';
        for (const session of sessions) assert.ok(!('error' in await session.rpc(method, params)));
    };
    try {
        assert.equal(await check('initial full check'), 0);
        let count = 0;
        let seed = 7291;
        for (let i = 0; i < 8; i++) {
            seed ^= seed << 13;
            seed ^= seed >>> 17;
            seed ^= seed << 5;
            const result = String((seed >>> 0) % (i % 2 === 0 ? 1e8 : 10));
            await edit(original.replace('    42\n', '    ' + result + '\n'));
            assert.equal(await check('changed integer result ' + i), ++count);
        }
        await edit(original);
        assert.equal(await check('restore integer result'), ++count);
        await edit(original.replace('    42\n', '    42.5\n'));
        assert.equal(await check('changed result type'), count);
        await edit(original);
        assert.equal(await check('restore after changed result type'), count);
        for (let seed of [17, 863]) {
            for (let i = 0; i < 4; i++) {
                seed ^= seed << 13;
                seed ^= seed >>> 17;
                seed ^= seed << 5;
                const inserted = '    val deliberatelyUnused' + (seed >>> 0) + ' = ' + i + '\n';
                const candidate = original.replace('    42', inserted + '    42');
                await edit(candidate);
                assert.equal(await check('unused binding ' + i), count + 1);
                count++;
                const replacement = candidate.replace(' = ' + i + '\n', ' = ' + (100 + i) + '\n');
                await edit(replacement);
                assert.equal(await check('longer initializer ' + i), count + 1);
                count++;
                const shorter = replacement.replace(' = ' + (100 + i) + '\n', ' = ' + (i + 1) + '\n');
                await edit(shorter);
                assert.equal(await check('shorter initializer ' + i), count + 1);
                count++;
                await edit(candidate.replace('    42', '    intentionallyMissing()'));
                assert.equal(await check('changed expression ' + i), count);
                await edit(original);
                assert.equal(await check('restore ' + i), count);
            }
        }
        const log = fs.readFileSync(replay.log, 'utf8');
        assert.ok(!/abla-analysis-check.*(?:DIFFERENT|FAILED)/.test(log), log);
    } finally {
        await Promise.all(sessions.map(session => session.close()));
    }
}

async function incrementalUnusedImportReplay() {
    const original = 'import "factory.ab"\nimport "method.ab"\nimport "unused.ab"\nfun answer: int {\n    val positive = makeProbe().valueNow()\n    42\n}\n';
    const p = fixture('unused-import-replay', {
        'abla.toml': 'name = "unused-import-replay"\nentry = "main.ab"\nvisibility = "imports"\n',
        'main.ab': 'import "dep.ab"\nfun main: int = answer()\n',
        'dep.ab': original,
        'factory.ab': 'class Probe(val item: int)\nfun makeProbe(): Probe = Probe(1)\n',
        'method.ab': 'import "factory.ab"\nfun Probe.valueNow(): int = this.item\n',
        'unused.ab': 'fun anotherThing(): int = 0\n',
    });
    const file = path.join(p, 'dep.ab');
    const options = { mode: 'graph-v2', unusedImports: true };
    const env = { ...process.env, ABLA_ANALYSIS_INCREMENTAL_TRACE: '1', ABLA_ANALYSIS_CHECK: '1' };
    delete env.ABLA_ANALYSIS_INCREMENTAL_TYPING;
    const replay = await start(p, { ...options, env, log: 'replay.stderr' });
    const full = await start(p, { ...options, env: { ...env, ABLA_ANALYSIS_INCREMENTAL_TYPING: '0', ABLA_ANALYSIS_CHECK: '0' }, log: 'full.stderr' });
    const sessions = [replay, full];
    let revision;
    const check = async (text, expectedHits, warnings) => {
        const [snapshot, reference] = await Promise.all(sessions.map(s => s.analyze()));
        assert.equal(snapshot.complete, true);
        assert.deepEqual(snapshot, reference);
        const edited = doc(snapshot, file);
        assert.deepEqual(edited.diagnostics.map(d => d.code), Array(warnings).fill('W_UNUSED_IMPORT'));
        const diagnostic = edited.diagnostics.find(d => d.message.includes('unused.ab'));
        assert.ok(diagnostic, JSON.stringify(edited.diagnostics));
        const [{ range, newText }] = diagnostic.fixes[0].edits;
        assert.equal(newText, '');
        const removed = Buffer.from(text).subarray(range.start, range.end).toString();
        assert.equal(removed, 'import "unused.ab"\n');
        if (revision !== undefined) {
            const [actual, expected] = await Promise.all(sessions.map(s => s.rpc('analyze', { since: revision })));
            assert.deepEqual(actual, expected);
        }
        revision = snapshot.revision;
        const log = fs.readFileSync(replay.log, 'utf8');
        assert.equal(log.match(/replayed a type-inert/g)?.length ?? 0, expectedHits, log);
        assert.ok(!/abla-analysis-check.*(?:DIFFERENT|FAILED)/.test(log), log);
    };
    try {
        await check(original, 0, 1);
        let version = 0;
        const edit = async text => {
            const params = { uri: uri(file), version: ++version, text };
            for (const session of sessions) {
                assert.ok(!('error' in await session.rpc(version === 1 ? 'document/open' : 'document/change', params)));
            }
        };
        const results = [765432, 9, 812, 4];
        for (const [index, value] of results.entries()) {
            const text = original.replace('    42\n', '    ' + value + '\n');
            await edit(text);
            await check(text, index + 1, 1);
        }
        let hits = results.length;
        const beforeComment = original.replace('    42\n', '    4\n');
        for (const comment of ['    // Explain the calculation.\n', '    // Shorter.\n', '']) {
            const text = beforeComment.replace('    val positive', comment + '    val positive');
            await edit(text);
            await check(text, ++hits, 1);
        }
        const outside = beforeComment.replace('fun answer: int', '// Document the public answer.\nfun answer: int');
        await edit(outside);
        await check(outside, hits, 1);
        await edit(beforeComment);
        await check(beforeComment, hits, 1);
        const text = original.replace('makeProbe().valueNow()', '0');
        await edit(text);
        await check(text, hits, 3);
    } finally {
        await Promise.all(sessions.map(session => session.close()));
    }
}

async function idiomHints(mode) {
    const source = `// café
import "abla/array"
resource class Ticket(val value: int)
var calls = 0
fun next(): int? { calls = calls + 1; 3 }
fun effect(value: int): int { calls = calls + 1; value }
fun early(input: int?): int {
    val value = input
    if (value == null) return 0
    value + 1
}
fun bare(input: int?): void {
    val value = input
    if (value == null) return
    calls = calls + value
}
fun skipped(inputs: array<int?>): int {
    var count = 0
    for (input in inputs) {
        val value = input
        if (null == value) { continue }
        count = count + value
    }
    count
}
fun afterCall(): int {
    val value = next()
    if (value == null) return 0
    value
}
fun guarded(input: int?): int {
    val value = input
    if (value == null) {
        effect(0)
        return 0
    }
    value
}
fun fallback(input: int?): int {
    val value = input
    if (value == null) return effect(0)
    value
}
fun commented(input: int?): int {
    val value = input
    // Keep this explanation with the early exit.
    if (value == null) return 0
    value
}
fun annotated(input: int?): int {
    val value: int? = input
    if (value == null) return 0
    value
}
fun mappedLoop(input: array<int>): array<int> {
    val output: array<int> = []
    for (value in input) { output.append((value + 2) * 3) }
    output
}
fun mappedText(input: array<string>): array<string> {
    val output: array<string> = []
    for (word in input) output.append("hello $word")
    output
}
fun extra(input: array<int>): array<int> {
    val output: array<int> = []
    for (value in input) {
        effect(value)
        output.append(value + 1)
    }
    output
}
fun effects(input: array<int>): array<int> {
    val output: array<int> = []
    for (value in input) output.append(effect(value))
    output
}
fun grouped(input: array<int>): array<int> {
    val output: array<int> = ([])
    for (value in input) output.append(value + 1)
    output
}
fun resources(input: array<Ticket>): array<string> {
    val output: array<string> = []
    for (value in input) output.append("ticket")
    output
}
fun tickets(input: array<int>): array<Ticket> {
    val output: array<Ticket> = []
    for (value in input) output.append(Ticket(value))
    output
}
fun main: int {
    if (early(null) != 0 || early(2) != 3 || skipped([null, 2, null, 3]) != 5) return 1
    if (afterCall() != 3 || calls != 1) return 2
    bare(null)
    bare(2)
    if (calls != 3) return 4
    if (mappedLoop([1, 2])[1] != 12 || mappedText(["world"])[0] != "hello world") return 3
    0
}
`;
    const p = fixture(`idiom-hints-${mode}`, { 'main.ab': source });
    const entry = path.join(p, 'main.ab');
    const session = await start(p, { mode });
    try {
        const snapshot = await session.analyze();
        assert.equal(snapshot.complete, true);
        const diagnostics = doc(snapshot, entry).diagnostics;
        assert.ok(diagnostics.every((d) => d.severity === 'warning'), JSON.stringify(diagnostics));
        const expected = [
            ['W_NULLABLE_EARLY_EXIT', 'val value = input ?? return 0'],
            ['W_NULLABLE_EARLY_EXIT', 'val value = input ?? return'],
            ['W_NULLABLE_EARLY_EXIT', 'val value = input ?? continue'],
            ['W_COMPOUND_ASSIGNMENT', 'count +='],
            ['W_NULLABLE_EARLY_EXIT', 'val value = next() ?? return 0'],
            ['W_ARRAY_MAPPED', 'val output: array<int> = input.mapped { value -> (value + 2) * 3 }'],
            ['W_ARRAY_MAPPED', 'val output: array<string> = input.mapped { word -> "hello $word" }'],
        ];
        assert.deepEqual(diagnostics.map((d) => [d.code, d.fixes?.[0]?.edits?.[0]?.newText]), expected);
        let edited = Buffer.from(source);
        const edits = diagnostics.flatMap((d) => d.fixes.flatMap((fix) => fix.edits));
        for (const { range, newText } of edits.reverse()) {
            edited = Buffer.concat([edited.subarray(0, range.start), Buffer.from(newText), edited.subarray(range.end)]);
        }
        await session.rpc('document/open', { uri: uri(entry), version: 1, text: edited.toString() });
        noErrors(await session.analyze());
        const output = path.join(p, 'program');
        for (const text of [source, edited]) {
            fs.writeFileSync(entry, text);
            const built = spawnSync(compiler, ['build', entry, '-o', output, '--no-cache'], { encoding: 'utf8' });
            assert.equal(built.status, 0, built.stderr);
            assert.equal(spawnSync(output, []).status, 0, 'example behavior changed');
        }
    } finally {
        await session.close();
    }
}

async function idiomMappedVisibility() {
    const loop = `fun map(input: array<int>): array<int> {
    val result: array<int> = []
    for (item in input) result.append(item + 1)
    result
}
fun main: int = map([1])[0] - 2
`;
    for (const [name, prefix] of [
        ['missing', ''],
        ['alias', 'import "abla/array" as collections\n'],
        ['overload', 'import "abla/array"\nfun array<int>.mapped(transform: (int) -> int): array<int> = [99]\n'],
        ['operator', 'import "abla/array"\nclass Counter(val value: int)\noperator fun Counter.plus(rhs: Counter): Counter = rhs\n'],
    ]) {
        const project = fixture(`idiom-mapped-${name}`, { 'main.ab': prefix + loop });
        const session = await start(project, { mode: 'graph-v2' });
        try {
            noErrors(await session.analyze());
        } finally {
            await session.close();
        }
    }
}


async function logicalAssignmentFix(mode) {
    const source = `var flag = true
class Switch(var enabled: bool)
fun tick(var counter: array<int>): bool {
    counter[0] += 1
    false
}
fun Switch.update(): void {
    this.enabled = this.enabled && true
    return
}
fun main: int {
    val counter = [0]
    var enabled = true
    enabled = enabled && tick(counter)
    enabled = enabled || (true && true)
    enabled = enabled /* keep this */ && true
    flag = flag && tick(counter)
    val box = Switch(true)
    box.update()
    if (enabled && box.enabled && !flag && counter[0] == 2) 0 else 1
}
`;
    const project = fixture(`logical-assignment-${mode}`, { 'main.ab': source });
    const entry = path.join(project, 'main.ab');
    const session = await start(project, { mode });
    try {
        const snapshot = await session.analyze();
        assert.equal(snapshot.complete, true);
        const diagnostics = doc(snapshot, entry).diagnostics;
        assert.ok(diagnostics.every((d) => d.severity === 'warning'), JSON.stringify(diagnostics));
        assert.deepEqual(diagnostics.map((d) => d.code), ['W_LOGICAL_ASSIGNMENT', 'W_LOGICAL_ASSIGNMENT']);
        const edits = diagnostics.map((d) => d.fixes[0].edits[0]);
        assert.deepEqual(edits.map((edit) => edit.newText), ['enabled &&=', 'enabled ||=']);
        let edited = Buffer.from(source);
        for (const { range, newText } of edits.reverse()) {
            edited = Buffer.concat([edited.subarray(0, range.start), Buffer.from(newText), edited.subarray(range.end)]);
        }
        await session.rpc('document/open', { uri: uri(entry), version: 1, text: edited.toString() });
        const after = await session.analyze();
        noErrors(after);
        assert.ok(!doc(after, entry).diagnostics.some((d) => d.code === 'W_LOGICAL_ASSIGNMENT'));
        const output = path.join(project, 'program');
        for (const text of [source, edited]) {
            fs.writeFileSync(entry, text);
            const built = spawnSync(compiler, ['build', entry, '-o', output, '--no-cache'], { encoding: 'utf8' });
            assert.equal(built.status, 0, built.stderr);
            assert.equal(spawnSync(output, []).status, 0, 'Boolean assignment edit changed behavior');
        }
    } finally {
        await session.close();
    }
}

// Apply every first fix of the given codes, check the edited text analyzes cleanly with none left, and that both programs exit 0.
async function applyHintFixes(session, project, entry, source, codes, label) {
    const snapshot = await session.analyze();
    assert.equal(snapshot.complete, true);
    const diagnostics = doc(snapshot, entry).diagnostics.filter((d) => codes.includes(d.code));
    assert.ok(diagnostics.every((d) => d.severity === 'warning'), JSON.stringify(diagnostics));
    const edits = diagnostics.map((d) => d.fixes[0].edits[0]);
    let edited = Buffer.from(source);
    for (const { range, newText } of [...edits].sort((a, b) => b.range.start - a.range.start)) {
        edited = Buffer.concat([edited.subarray(0, range.start), Buffer.from(newText), edited.subarray(range.end)]);
    }
    await session.rpc('document/open', { uri: uri(entry), version: 1, text: edited.toString() });
    const after = await session.analyze();
    noErrors(after);
    assert.ok(!doc(after, entry).diagnostics.some((d) => codes.includes(d.code)), JSON.stringify(doc(after, entry).diagnostics));
    const output = path.join(project, 'program');
    for (const text of [source, edited.toString()]) {
        fs.writeFileSync(entry, text);
        const built = spawnSync(compiler, ['build', entry, '-o', output, '--no-cache'], { encoding: 'utf8' });
        assert.equal(built.status, 0, built.stderr);
        assert.equal(spawnSync(output, []).status, 0, `${label} edit changed behavior`);
    }
    return { diagnostics, edited: edited.toString() };
}

// `x = x op e` for an ordinary mutable local becomes `x op= e` (the same tree). Globals, fields, a left-nested operand
// (`x - a - b` is `(x - a) - b`), a parenthesized read, a comment and an existing compound are left alone; a shadowing local is its own.
async function compoundAssignmentFix(mode) {
    const source = `var total = 0
class Box(var count: int)
fun Box.bump(): void {
    this.count = this.count + 1
    count = count + 1
}
fun main: int {
    var n = 1
    n = n + 2
    n = n - 1
    n = n * 3
    n=n+1
    n = n / 2
    n = n % 4
    var s = "a"
    s = s + "b"
    var m = 10
    m = m - 2 - 3
    m = (m) + 1
    m = m /* keep */ + 1
    m += 1
    if (true) {
        var m = 0
        m = m + 1
        if (m != 1) return 3
    }
    total = total + 1
    val box = Box(0)
    box.bump()
    if (n != 3 || s != "ab" || m != 8 || total != 1 || box.count != 2) 1 else 0
}
`;
    const project = fixture(`compound-assignment-${mode}`, { 'main.ab': source });
    const entry = path.join(project, 'main.ab');
    const session = await start(project, { mode });
    try {
        const { diagnostics } = await applyHintFixes(session, project, entry, source, ['W_COMPOUND_ASSIGNMENT'], 'compound assignment');
        assert.deepEqual(diagnostics.map((d) => d.fixes[0].edits[0].newText),
            ['n +=', 'n -=', 'n *=', 'n += ', 'n /=', 'n %=', 's +=', 'm +=']);
    } finally {
        await session.close();
    }
}

// An index loop whose index has no other use becomes `for (x in xs)`. Bodies that grow or shrink the array keep their behavior
// (both forms read the size once). A used index, a reassigned or field source, a class element, a typed binding and a label
// are left alone.
async function indexLoopFix(mode) {
    const source = `import "abla/array"
class Item(val v: int)
fun sum(xs: array<int>): int {
    var total = 0
    for (i in 0 until xs.size) {
        val x = xs[i]
        total += x
    }
    total
}
fun codes(text: string): int {
    var total = 0
    for (k in 0 until text.size) {
        val c = text[k]
        total += c
    }
    total
}
fun grow(): int {
    val a = [1, 2, 3]
    var n = 0
    for (i in 0 until a.size) {
        val x = a[i]
        if (a.size < 6) a.append(x * 10)
        n += 1
    }
    n + a.size
}
fun used(xs: array<int>): int {
    var total = 0
    for (i in 0 until xs.size) {
        val x = xs[i]
        total += x * i
    }
    total
}
fun reassigned(): int {
    var xs = [1, 2]
    var total = 0
    for (i in 0 until xs.size) {
        val x = xs[i]
        total += x
        xs = [5, 6]
    }
    total
}
fun objects(xs: array<Item>): int {
    var total = 0
    for (i in 0 until xs.size) {
        val x = xs[i]
        total += x.v
    }
    total
}
fun typed(xs: array<int>): int {
    var total = 0
    for (i in 0 until xs.size) {
        val x: int = xs[i]
        total += x
    }
    total
}
fun main: int {
    if (sum([1, 2, 3]) != 6 || codes("ab") != 195 || grow() != 9) return 1
    if (used([1, 2]) != 2 || reassigned() != 7 || objects([Item(4)]) != 4 || typed([2]) != 2) return 2
    0
}
`;
    const project = fixture(`index-loop-${mode}`, { 'main.ab': source });
    const entry = path.join(project, 'main.ab');
    const session = await start(project, { mode });
    try {
        const { diagnostics, edited } = await applyHintFixes(session, project, entry, source, ['W_INDEX_LOOP'], 'index loop');
        assert.deepEqual(diagnostics.map((d) => d.fixes[0].edits[0].newText),
            ['for (x in xs) {', 'for (c in text) {', 'for (x in a) {']);
        assert.ok(edited.includes('for (x in xs) {\n        total += x\n'), edited);
    } finally {
        await session.close();
    }
}

// A repeated analyze of an unchanged revision is answered from the held answer without reloading the project (#1132), and every change
// a reload would see without an overlay still gives a new revision: a file edited on disk (same size), a file that appears and changes
// where an import resolves (a prepared package beside the vendored one), and the manifest.
async function unchangedInputs() {
    const rev = '1'.repeat(40);
    const digest = '2'.repeat(40);
    fs.rmSync(path.join(root, 'unchanged-inputs'), { recursive: true, force: true });
    const p = fixture('unchanged-inputs', {
        'main.ab': 'import "dep.ab"\nimport "package/pkg"\nfun main: int = answer() + pkgValue()\n',
        'dep.ab': 'fun answer: int = 42\n',
        'abla.lock': `version = 2\n\n[[package]]\nname = "pkg"\nprovider = "git"\nidentity = "git:/nowhere"\nsource = "/nowhere"\nselector-kind = "branch"\nselector = "main"\nrevision = "${rev}"\ndigest = "${digest}"\nentry = "pkg.ab"\n`,
        'vendor/pkg/.abla-revision': rev,
        'vendor/pkg/.abla-digest': digest,
        'vendor/pkg/pkg.ab': 'fun pkgValue: int = 1\n',
    });
    const log = 'unchanged.stderr';
    const s = await start(p, { mode: 'graph-v2', log, env: { ...process.env, ABLA_ANALYSIS_INCREMENTAL_TRACE: '1' } });
    const held = () => (fs.readFileSync(path.join(p, log), 'utf8').match(/unchanged inputs: held answer/g) ?? []).length;
    const text = (result, file) => result.documents.find(d => d.uri.endsWith(file))?.text;
    const a = await s.analyze();
    assert.ok(a.complete, JSON.stringify(a.issues));
    const b = await s.analyze();
    assert.equal(b.revision, a.revision);
    assert.deepEqual(b.documents.map(d => [d.uri, d.text]), a.documents.map(d => [d.uri, d.text]));
    assert.equal(held(), 1, 'an unchanged revision was reloaded');
    // On disk, the same size: a new revision with the new text.
    fs.writeFileSync(path.join(p, 'dep.ab'), 'fun answer: int = 43\n');
    const c = await s.analyze();
    assert.notEqual(c.revision, b.revision);
    assert.equal(text(c, '/dep.ab'), 'fun answer: int = 43\n');
    assert.equal(held(), 1);
    // A prepared copy appears: `package/pkg` now resolves to it, not to vendor/.
    fs.mkdirSync(path.join(p, '.abla/packages/pkg/source'), { recursive: true });
    fs.writeFileSync(path.join(p, '.abla/packages/pkg/revision'), rev);
    fs.writeFileSync(path.join(p, '.abla/packages/pkg/entry.ab'), 'import "source/pkg.ab"\n');
    fs.writeFileSync(path.join(p, '.abla/packages/pkg/source/pkg.ab'), 'fun pkgValue: int = 2\n');
    const d = await s.analyze();
    assert.notEqual(d.revision, c.revision);
    assert.ok(d.documents.some(doc => doc.uri.includes('/.abla/packages/pkg/')), JSON.stringify(d.documents.map(doc => doc.uri)));
    assert.equal(held(), 1);
    // The manifest.
    fs.appendFileSync(path.join(p, 'abla.toml'), '# changed\n');
    const e = await s.analyze();
    assert.notEqual(e.revision, d.revision);
    assert.equal(held(), 1);
    // And unchanged again: held.
    const f = await s.analyze();
    assert.equal(f.revision, e.revision);
    assert.equal(held(), 2);
    await s.close();
}

const tests = { unchanged_inputs: unchangedInputs, compound_assignment: () => compoundAssignmentFix('graph-v1'), compound_assignment_v2: () => compoundAssignmentFix('graph-v2'), index_loop: () => indexLoopFix('graph-v1'), index_loop_v2: () => indexLoopFix('graph-v2'), logical_assignment: () => logicalAssignmentFix('graph-v1'), logical_assignment_v2: () => logicalAssignmentFix('graph-v2'), idiom_mapped_visibility: idiomMappedVisibility, idiom_hints: () => idiomHints('graph-v1'), idiom_hints_v2: () => idiomHints('graph-v2'), body_replay: incrementalBodyReplay, unused_import_replay: incrementalUnusedImportReplay, regex_definitions: typedRegexDefinitions, validate_occurrences: validateOccurrences, sql: sqlSubparsers, subparsers, documentation: () => documentation('graph-v1'), documentation_v2: () => documentation('graph-v2'), field_assign: () => fieldAssign('graph-v1'), field_assign_v2: () => fieldAssign('graph-v2'), builtins: () => builtins('graph-v1'), builtins_v2: () => builtins('graph-v2'), local_names: () => localNames('graph-v1'), local_names_v2: () => localNames('graph-v2'), type_names: () => typeNames('graph-v1'), type_names_v2: () => typeNames('graph-v2'), since, edit_sequence: editSequence, edit_sequence_v2: () => editSequence('graph-v2'), stable_ids: stableIds, simple, alias_private: aliasPrivate, generic_fields: genericFields, no_eval: noEval, strict, symlinks, negative_protocol: negativeProtocol, packages, contract_surface: contractSurface, disk_revision: diskRevision, queries, projections, named_calls: namedCalls };
async function checkedScalarBody(calls = false, operators = false, locals = false, returns = false, strings = false, fields = false, extended = false, parens = false, loops = false, imported = false, globals = false, arrays = false, importedCalls = false, constructors = false, records = false) {
    // An imported class: declared in its own module. Imported functions: of two modules of the project and the standard library.
    const head = (imported ? 'import "./point.ab"\n' : '') + (importedCalls ? 'import "./lib.ab"\nimport "./other.ab"\nimport "abla/bits"\n' : '') + (constructors ? 'import "./box.ab"\n' : '') + (records ? 'fun answer(left: int, right: int, ps: array<Pair>): int ' : arrays ? 'fun answer(left: int, right: int, xs: array<int>, names: array<string>): int ' : locals || returns || loops ? 'fun answer(left: int, right: int): int ' : strings ? 'fun answer(left: int, right: int, text: string): int = '
        : fields ? 'fun answer(left: int, right: int, p: Point): int = ' : constructors ? 'fun answer(left: int, right: int, q: Pair): int = ' : 'fun answer(left: int, right: int): int = ');
    // A field of another type (`tags`) is never read, but does not keep the class from the checker.
    // `inner` is of another plain class, whose fields a chain `p.inner.k` reads.
    const point = 'class Inner(val k: int, val tag: string = "i")\n' +
        'class Point(val x: int, var y: int, val label: string = "p", val tags: array<string> = [], val weights: array<int> = [], val inner: Inner = Inner(1)) {\n    fun total(): int = this.x + this.y\n    fun scaled(k: int): int = this.x * k\n    fun name(): string = this.label\n}\n';
    const block = (...lines) => '{\n' + lines.map(line => '    ' + line + '\n').join('') + '}';
    const initial = calls ? 'step(left) + right' : locals ? block('val t = left + right', 't') : returns ? block('if (left < 0) return right', 'left + right') : strings ? 'text.size + left' : fields ? 'p.x + left'
        : globals ? 'LIMIT + left' : records ? block('var s = ps.size', 'for (e in ps) s += e.a', 's + left') : constructors ? 'area(q) + left' : importedCalls ? 'twice(left) + other(right) + bitAnd(left, right)' : arrays ? block('var s = xs.size', 'for (x in xs) s += x', 's + left') : loops ? block('var s = 0', 'for (i in 0 until left) s += i', 's + right') : 'left + right';
    // A global `i`: the loop's `i` ends with the loop, so a later `i` is the global, left to full typing.
    const rest = '\nfun later(): int = 7\n' + (loops ? 'val i: int = 3\n' : '')
        // Global values after the function: their offsets move with each edit. `NAMES` is not a scalar.
        + (globals ? 'val LIMIT: int = 40\nval scale = 3\nvar counter: int = 0\nval NAMES: array<string> = []\n' : '') + (calls
        ? 'fun step(n: int): int = n + 1\nfun shift(n: int): int = n * 2\n' : '') + (fields && !imported ? point : '')
        // A plain class and a function that takes it; another module's are in box.ab.
        + (constructors || records ? 'class Pair(val a: int, val b: int, val name: string = "pair")\nfun area(q: Pair): int = q.a * q.b\n' : '');
    const main = 'import "./dep.ab"\n' + (imported ? 'import "./point.ab"\n' : '') + (importedCalls ? 'import "./shadow.ab"\n' : '') + (extended ? 'import "./ext.ab"\n' : '') + 'fun main: int = answer(2, 3' + (records ? ', [Pair(4, 5)]' : constructors ? ', Pair(4, 5)' : arrays ? ', [1, 2, 3], ["a", "b"]' : strings ? ', "abc"' : fields ? ', Point(4, 5)' : '') + ') + later()\n';
    const p = fixture(calls ? 'checked-calls' : operators ? 'checked-operators' : locals ? 'checked-locals' : returns ? 'checked-returns' : strings ? 'checked-strings' : extended ? 'checked-extended' : imported ? 'checked-imported' : globals ? 'checked-globals' : records ? 'checked-records' : constructors ? 'checked-constructors' : importedCalls ? 'checked-calls-imported' : arrays ? 'checked-arrays' : loops ? 'checked-loops' : parens ? 'checked-parens' : fields ? 'checked-fields' : 'checked-scalar', {
        'abla.toml': 'name = "checked-scalar"\nentry = "main.ab"\nvisibility = "imports"\n',
        'main.ab': main,
        'dep.ab': head + initial + rest,
        // An extension of the class: `p.x` is left to full typing.
        ...(imported ? { 'point.ab': point } : {}),
        ...(constructors ? { 'box.ab': 'class Box(val w: int, val h: int)\nfun volume(b: Box, d: int): int = b.w * b.h * d\n' } : {}),
        // `hidden` is private, `pair` overloaded, `withDefault` defaulted, and `bitOr` shadows the standard library's.
        ...(importedCalls ? {
            'lib.ab': 'fun twice(n: int): int = n * 2\nfun third(n: int): int = n / 3\nprivate fun hidden(n: int): int = n\n' +
                'fun pair(a: int): int = a\nfun pair(a: int, b: int): int = a + b\nfun withDefault(n: int, k: int = 1): int = n * k\n',
            'other.ab': 'fun other(n: int): int = n - 1\n',
            // Not imported by dep.ab, whose `bitOr` is the standard library's, but the project has two of that name.
            'shadow.ab': 'fun bitOr(left: int, right: int): int = left + right\n',
        } : {}),
        ...(extended ? { 'ext.ab': 'import "./dep.ab"\nfun Point.twice(): int = this.x * 2\n' } : {}),
    });
    const file = path.join(p, 'dep.ab');
    const options = { mode: 'graph-v2', unusedImports: true };
    const trace = { ...process.env, ABLA_ANALYSIS_INCREMENTAL_TRACE: '1' };
    const replay = await start(p, { ...options,
        env: { ...trace, ABLA_ANALYSIS_INCREMENTAL_TYPING: '2', ABLA_ANALYSIS_CHECK: '1' }, log: 'scalar.stderr' });
    const full = await start(p, { ...options,
        env: { ...trace, ABLA_ANALYSIS_INCREMENTAL_TYPING: '0', ABLA_ANALYSIS_CHECK: '0' }, log: 'full.stderr' });
    const sessions = [replay, full];
    let revision;
    let version = 0;
    const check = async (text, expectedHits) => {
        const [actual, expected] = await Promise.all(sessions.map(s => s.analyze()));
        assert.deepEqual(actual, expected);
        if (revision !== undefined) {
            const [delta, ref] = await Promise.all(sessions.map(s => s.rpc('analyze', { since: revision })));
            assert.deepEqual(delta, ref);
        }
        revision = actual.revision;
        const expression = text.slice(head.length, -rest.length);
        const field = expression.indexOf('p.');
        const foundUse = calls ? /(?:step|shift)\(/u.exec(expression)?.index : fields && field >= 0 ? field + 2 : expression.indexOf('left');
        const use = foundUse === undefined || foundUse < 0 ? -1 : head.length + foundUse;
        const editor = use < 0
            ? { uri: uri(path.join(p, 'main.ab')), offset: bytes(main.slice(0, main.indexOf('later()'))), revision }
            : { uri: uri(file), offset: bytes(text.slice(0, use)), revision };
        for (const method of ['query/definition', 'query/hover', 'query/references']) {
            const [found, ref] = await Promise.all(sessions.map(s => s.rpc(method, editor)));
            assert.deepEqual(found, ref);
        }
        const log = fs.readFileSync(replay.log, 'utf8');
        assert.equal(log.match(/rechecked one scalar body/g)?.length ?? 0, expectedHits, log);
        assert.ok(!/abla-analysis-check.*(?:DIFFERENT|FAILED)/.test(log), log);
        if (version === 1 || version === 8) {
            const at = bytes(text.slice(0, text.lastIndexOf('7')));
            const params = { baseRevision: revision, edits: [{ uri: uri(file), start: at, end: at + 1, newText: '8' }] };
            const [found, ref] = await Promise.all(sessions.map(s => s.rpc('refactor/validate', params)));
            assert.deepEqual(found, ref);
            assert.equal(found.result.valid, true, found.result.reason);
        }
    };
    const edit = async (expression, count) => {
        const text = head + expression + rest;
        version++;
        for (const session of sessions) {
            assert.ok(!('error' in await session.rpc(version === 1 ? 'document/open' : 'document/change', { uri: uri(file), version, text })));
        }
        await check(text, count);
    };
    try {
        await check(head + initial + rest, 0);
        let seed = 7907;
        let hits = 0;
        for (let i = 0; i < 8; i++) {
            seed ^= seed << 13;
            seed ^= seed >>> 17;
            seed ^= seed << 5;
            const n = (seed >>> 0) % 1000;
            const expression = calls
                ? (i % 2 ? 'step(right + ' + n + ')' : 'shift(left) + ' + n)
                : operators
                ? (i % 2 ? '(left / (right + ' + n + ')) % 7' : 'left << 2 | right ^ ' + n + ' & 255 >> 1 >>> 0')
                : locals
                ? (i % 2 ? block('val t: int = left * ' + n, 't % 7 + right') : block('val t = (right + ' + n + ') / 2', 't - left'))
                : returns
                ? (i % 2 ? block('if (left < ' + n + ') return right', 'left - right') : block('if (right > ' + n + ') { return left * 2 }', 'return left + right'))
                : strings
                ? (i % 2 ? 'text.size + left * ' + n : 'text[left % 3] + ' + n + ' - right')
                : fields
                ? (i % 2 ? 'p.y * ' + n + ' + right' : 'p.x - p.y + left + ' + n)
                // Bodies that end in a closing parenthesis, which the parsed expression ends before.
                : parens
                ? (i % 2 ? '(left + ' + n + ')' : 'left * (right - ' + n + ')')
                // An array of a class: its size, an element's fields, iteration, an element passed to a function.
                : records
                ? (i % 2 ? block('var s = 0', 'for (e in ps) s += e.a * ' + n + ' + area(e)', 'return s + ps[left % ps.size].b')
                    : block('var s = right', 'for (e in ps) if (e.name.size > ' + n + ') s += 1', 's'))
                // Constructor calls of a plain class, and class values passed to a function of the module.
                : constructors
                ? (i % 2 ? 'area(Pair(left, right + ' + n + ', "a")) + q.a' : 'area(q) * ' + n + ' - area(Pair(right, left, q.name))')
                : importedCalls
                ? (i % 2 ? 'twice(right + ' + n + ') + other(left) + bitXor(left, ' + n + ')' : 'third(left) * ' + n + ' + other(right) - bitAnd(right, ' + n + ')')
                // An array parameter's size, elements and iteration.
                : arrays
                ? (i % 2 ? block('var s = 0', 'for (x in xs) s += x * ' + n, 'return s + xs[left % xs.size]')
                    : block('var s = right', 'for (x in xs) if (x > ' + n + ') s += 1', 's'))
                : globals
                ? (i % 2 ? 'LIMIT * ' + n + ' + right' : 'left * scale + counter + ' + n)
                // Mutable locals, assignments, loops and their control.
                : loops
                ? (i % 2 ? block('var s = left', 'for (i in 0 until ' + n + ') s += i * right', 'return s')
                    : block('var s = right', 'for (i in left..' + n + ') {', '    if (i % 3 == 0) continue', '    s = s + i', '    if (s > 1000) break',
                        '}', 'while (s > ' + n + ') s -= 7', 'do { s += 1 } while (s < left)', 's'))
                : (i % 2 ? 'right + ' + n : 'left * ' + n + ' + right');
            await edit(expression, extended ? hits : ++hits);
        }
        // String values: a literal, compared with a string field, a string parameter or a local of written type `string`.
        if (fields) await edit('(if (p.label == "p") p.x else p.y) + left', extended ? hits : ++hits);
        // Member chains on string and scalar-array fields: their size and elements. Another array field's size: full typing.
        if (fields) await edit('p.label.size + p.weights.size * left', extended ? hits : ++hits);
        if (fields) await edit('p.weights[left] + p.label[0]', extended ? hits : ++hits);
        // Through a field of another class: its scalar and string fields.
        if (fields) await edit('p.inner.k * left + p.inner.tag.size', extended ? hits : ++hits);
        if (strings) await edit('if (text == "abc") left else right', ++hits);
        if (locals) await edit(block('val t: string = "ab"', 'if (t != "ab") left else right'), ++hits);
        // Another local: the document's symbols change, so full typing.
        if (locals) await edit(block('val t = left', 'val u = t + 1', 'u'), hits);
        // Back to one local: the symbols change again, so full typing.
        if (locals) await edit(block('val t: int = left', 't'), hits);
        // Calls of its scalar methods: rechecked alone. A method of another result type: full typing.
        if (fields) await edit('p.total() + p.scaled(left + 1) * right', extended ? hits : ++hits);
        if (fields) await edit('p.scaled(right) - p.x', extended ? hits : ++hits);
        if (fields) await edit('p.name().size + left', hits);
        if (fields) await edit('p.tags.size + left', hits);
        // A global that is not a scalar: full typing. (A local that shadows a global: checked_loops, its global `i`.)
        if (globals) await edit('NAMES.size + left', hits);
        // Another module's function that takes a class: full typing.
        if (constructors) await edit('volume(Box(left, 1), right) + area(q)', hits);
        // A constructor call that leaves a defaulted field out: full typing. Passing every field again: rechecked alone (only the new
        // body is given to the checker).
        if (constructors) await edit('area(Pair(left, right)) + left', hits);
        if (constructors) await edit('area(Pair(right, left)) + left', hits);
        if (constructors) await edit('area(Pair(right, left, "b")) + left', ++hits);
        if (constructors) await edit('area(Pair(left, right, "b")) + left', ++hits);
        if (importedCalls) {
            // The last use of `other.ab` goes: the import uses change (and W_UNUSED_IMPORT with them), so full typing. Then rechecked
            // alone, and the use comes back: full typing again.
            await edit('twice(left) + bitAnd(left, right)', hits);
            await edit('twice(right) + bitAnd(left, right)', ++hits);
            await edit('twice(left) + other(right) + bitAnd(left, right)', hits);
            await edit('twice(left) + other(left) + bitAnd(left, right)', ++hits);
            // A private function, an overload, a defaulted parameter and a name the standard library shares: full typing (and each
            // edit after one, whose old body was not checked alone).
            for (const call of ['hidden(left)', 'pair(left)', 'withDefault(left)', 'bitOr(left, right)', 'twice(right)']) {
                await edit(call + ' + other(left) + bitAnd(left, right)', hits);
            }
            await edit('twice(left) + other(left) + bitAnd(left, right)', ++hits);
            // The callee's interface changes in an unsaved buffer, then the caller's body: each answer is full typing's.
            const library = path.join(p, 'lib.ab');
            const original = fs.readFileSync(library, 'utf8');
            let libraryVersion = 0;
            const change = async text => {
                libraryVersion++;
                for (const session of sessions) {
                    assert.ok(!('error' in await session.rpc(libraryVersion === 1 ? 'document/open' : 'document/change', { uri: uri(library), version: libraryVersion, text })));
                }
                const [actual, expected] = await Promise.all(sessions.map(s => s.analyze()));
                assert.deepEqual(actual, expected);
                revision = actual.revision;
            };
            // While `twice` returns `bool`, the body is an error, which full typing reports. Once the library is back (fully typed again,
            // clean), the next body edits are rechecked alone, against the restored interface.
            await change(original.replace('fun twice(n: int): int = n * 2', 'fun twice(n: int): bool = n > 2'));
            await edit('twice(right) + other(left) + bitAnd(left, right)', hits);
            await change(original);
            await edit('twice(left) + other(left) + bitAnd(left, right)', ++hits);
            await edit('twice(left) + other(right) + bitAnd(left, right)', ++hits);
        }
        // A call of an array's method: full typing (and again from there), then rechecked alone.
        if (arrays) await edit(block('var s = 0', 'for (x in xs) s += x', 'xs.indexOf(s) + s'), hits);
        if (arrays) await edit(block('var s = 0', 'for (x in xs) s += x', 's - xs[0]'), hits);
        if (arrays) await edit(block('var s = 0', 'for (x in xs) s += x', 's - xs[1]'), ++hits);
        // An array of strings: its size, an element compared, iteration.
        if (arrays) await edit(block('var s = names.size', 'for (x in names) if (x == "a") s += 1', 'if (names[0] != "b") s else left'), ++hits);
        // From a body that was not checked alone: full typing; then rechecked alone.
        if (globals) await edit('LIMIT - scale * counter', hits);
        if (globals) await edit('LIMIT - scale * counter + 1', ++hits);
        // After the loop, `i` is the global (the loop's ends with it): rechecked alone, the read the global's.
        if (loops) await edit(block('var s = 0', 'for (i in 0 until left) s += i', 's + i'), ++hits);
        // An assignment of a `val`, and a `for` over a call: full typing.
        if (loops) await edit(block('val s = 0', 'for (i in 0 until left) s = i', 's'), hits);
        if (loops) await edit(block('var s = 0', 'for (i in later() until left) s += i', 's'), hits);
        // Back to the first loop: rechecked alone.
        if (loops) await edit(block('var s = 1', 'for (i in 0 until right) s *= 2', 's'), ++hits);
        await edit(records ? block('var s = 0', 'for (e in ps) s += e.a + true', 's') : constructors ? 'area(Pair(true, 1, "c")) + left' : importedCalls ? 'twice(true) + other(left) + bitAnd(left, right)' : calls ? 'step(true)' : operators ? 'left / true' : loops ? block('var s = 0', 'for (i in 0 until left) s += true', 's') : globals ? 'LIMIT + true' : arrays ? block('var s = 0', 'for (x in xs) s += true', 's') : locals ? block('val t: bool = left', '1') : returns ? block('if (left) return 1', '0') : strings ? 'text[true]' : fields ? 'p.label + 1' : 'true', hits);
        await edit(initial, hits);
        await edit(records ? block('var s = 0', 'for (e in ps) s += e.missing', 's') : constructors ? 'area(missing) + left' : importedCalls ? 'twice(left) + other(left) + missing(left)' : calls ? 'missing(left)' : arrays ? block('var s = 0', 'for (x in xs) s += missing', 's') : loops ? block('var s = 0', 'for (i in 0 until left) s += missing', 's') : locals ? block('val left = 1', 'left') : returns ? block('if (left < 1) return missing', 'left') : fields ? 'p.z + left' : 'left + missing', hits);
        await edit(calls ? 'step(right)' : locals || returns || loops || arrays || records ? block('right') : 'right', hits);
        await edit(calls ? 'shift(left)' : locals || returns || loops || arrays || records ? block('return left') : 'left', extended ? hits : ++hits);
    } finally {
        await Promise.all(sessions.map(s => s.close()));
    }
}

tests.checked_scalar = checkedScalarBody;
tests.checked_calls = () => checkedScalarBody(true);
tests.checked_operators = () => checkedScalarBody(false, true);
tests.checked_locals = () => checkedScalarBody(false, false, true);
tests.checked_returns = () => checkedScalarBody(false, false, false, true);
tests.checked_strings = () => checkedScalarBody(false, false, false, false, true);
tests.checked_fields = () => checkedScalarBody(false, false, false, false, false, true);
tests.checked_parens = () => checkedScalarBody(false, false, false, false, false, false, false, true);
tests.checked_loops = () => checkedScalarBody(false, false, false, false, false, false, false, false, true);
tests.checked_arrays = () => checkedScalarBody(false, false, false, false, false, false, false, false, false, false, false, true);
tests.checked_calls_imported = () => checkedScalarBody(false, false, false, false, false, false, false, false, false, false, false, false, true);
tests.checked_constructors = () => checkedScalarBody(false, false, false, false, false, false, false, false, false, false, false, false, false, true);
tests.checked_records = () => checkedScalarBody(false, false, false, false, false, false, false, false, false, false, false, false, false, false, true);
tests.checked_globals = () => checkedScalarBody(false, false, false, false, false, false, false, false, false, false, true);
tests.checked_fields_imported = () => checkedScalarBody(false, false, false, false, false, true, false, false, false, true);
tests.checked_fields_extended = () => checkedScalarBody(false, false, false, false, false, true, true);

tests.checked_interface = async () => {
    const base = 'fun interfaceSample(): int = 2+2\n';
    const reader = 'import "./provider.ab"\nfun sameSample(): bool = interfaceSample() == interfaceSample()\n';
    const root = fixture('checked-interface', {
        'abla.toml': 'name = "checked-interface"\nentry = "main.ab"\nvisibility = "imports"\n',
        'main.ab': 'import "./reader.ab"\nfun main: int = if (sameSample()) 0 else 1\n',
        'reader.ab': reader,
        'provider.ab': base,
    });
    const provider = uri(path.join(root, 'provider.ab'));
    const dependent = uri(path.join(root, 'reader.ab'));
    const offset = bytes(reader.slice(0, reader.indexOf('interfaceSample')));
    const env = { ...process.env, ABLA_ANALYSIS_INCREMENTAL_TRACE: '1' };
    const replay = await start(root, { mode: 'graph-v2', unusedImports: true,
        env: { ...env, ABLA_ANALYSIS_INCREMENTAL_TYPING: '2', ABLA_ANALYSIS_CHECK: '1' }, log: 'interface.stderr' });
    const full = await start(root, { mode: 'graph-v2', unusedImports: true,
        env: { ...env, ABLA_ANALYSIS_INCREMENTAL_TYPING: '0', ABLA_ANALYSIS_CHECK: '0' }, log: 'full.stderr' });
    const sessions = [replay, full];
    let revision;
    const check = async expected => {
        const [actual, oracle] = await Promise.all(sessions.map(s => s.analyze()));
        assert.deepEqual(actual, oracle);
        if (revision !== undefined) {
            const [delta, ref] = await Promise.all(sessions.map(s => s.rpc('analyze', { since: revision })));
            assert.deepEqual(delta, ref);
        }
        revision = actual.revision;
        for (const method of ['query/definition', 'query/hover', 'query/references']) {
            const params = { uri: dependent, offset, revision };
            const [reply, ref] = await Promise.all(sessions.map(s => s.rpc(method, params)));
            assert.deepEqual(reply, ref);
        }
        const log = fs.readFileSync(replay.log, 'utf8');
        assert.equal(log.match(/rechecked scalar interface and dependents/g)?.length ?? 0, expected, log);
        assert.doesNotMatch(log, /abla-analysis-check.*(?:DIFFERENT|FAILED)/);
    };
    try {
        await check(0);
        let seed = 8917;
        for (let i = 1; i <= 10; i++) {
            seed ^= seed << 13;
            seed ^= seed >>> 17;
            seed ^= seed << 5;
            const digit = (seed >>> 0) % 10;
            const body = i % 2 ? 'f64 = ' + digit + '.0' : 'int = ' + digit + '+1';
            for (const session of sessions) {
                const reply = await session.rpc(i === 1 ? 'document/open' : 'document/change', {
                    uri: provider, version: i, text: 'fun interfaceSample(): ' + body + '\n',
                });
                assert.ok(!('error' in reply));
            }
            await check(i);
        }
        const start = base.indexOf('int =');
        const [checked, oracle] = await Promise.all(sessions.map(s => s.rpc('refactor/validate', {
            baseRevision: revision, edits: [{ uri: provider, start, end: bytes(base) - 1, newText: 'f64 = 4.0' }],
        })));
        assert.deepEqual(checked, oracle);
        assert.equal(checked.result.valid, true, checked.result.reason);
        const extraReader = reader + 'fun anotherCondition(): bool = true\n' +
            'fun withAnotherCall(): bool = anotherCondition() && (interfaceSample() == interfaceSample())\n';
        for (const session of sessions) {
            const reply = await session.rpc('document/open', { uri: dependent, version: 1, text: extraReader });
            assert.ok(!('error' in reply));
        }
        await check(10);
        for (const session of sessions) {
            const reply = await session.rpc('document/change', {
                uri: provider, version: 11, text: 'fun interfaceSample(): f64 = 4.0\n',
            });
            assert.ok(!('error' in reply));
        }
        await check(10);
        assert.match(fs.readFileSync(replay.log, 'utf8'), /fallback: interface dependencies/);
        for (const session of sessions) {
            const reply = await session.rpc('document/change', {
                uri: provider, version: 12, text: 'fun interfaceSample(): bool = true\n',
            });
            assert.ok(!('error' in reply));
        }
        await check(10);
    } finally {
        await Promise.all(sessions.map(s => s.close()));
    }
};

const filter = process.env.ANALYSIS_TEST_FILTER ? process.env.ANALYSIS_TEST_FILTER.split(',') : null;
for (const [name, test] of Object.entries(tests)) {
    if (filter && !filter.includes(name)) continue;
    await test();
    console.log('ok', name);
}
console.log('analysis graph: protocol fixtures passed');
