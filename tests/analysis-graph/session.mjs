// Protocol-only fixtures for `ablac analyze --stdio`. Run against a built compiler; never
// executes source compile-time code. Usage: node session.mjs COMPILER
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
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
    constructor(project, { graph = true, mode = 'graph-v1' } = {}) {
        this.id = 0;
        this.project = project;
        this.graph = graph;
        this.mode = mode;
    }
    async start() {
        const stderr = fs.openSync(path.join(this.project, 'service.stderr'), 'w');
        this.process = spawn(compiler, ['analyze', '--stdio'], { stdio: ['pipe', 'pipe', stderr] });
        fs.closeSync(stderr);
        this.exit = new Promise((resolve) => this.process.on('close', resolve));
        this.lines = readline.createInterface({ input: this.process.stdout })[Symbol.asyncIterator]();
        const params = { workspaceRoots: [this.project], clientName: 'graph-fixture', clientVersion: '1' };
        if (this.graph) params.analysisMode = this.mode;
        const init = (await this.rpc('initialize', params)).result;
        assert.equal(init.protocolVersion, 1);
        assert.equal(init.capabilities.includes('module-graph-analysis-v1'), this.graph);
        assert.equal(init.capabilities.includes('stable-declaration-ids-v1'), this.graph && this.mode === 'graph-v2');
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
        if (this.graph) assert.equal(result.analysisMode, this.mode);
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
        '    for (item in items) sum = sum + item',
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

const tests = { local_names: () => localNames('graph-v1'), local_names_v2: () => localNames('graph-v2'), type_names: () => typeNames('graph-v1'), type_names_v2: () => typeNames('graph-v2'), since, edit_sequence: editSequence, edit_sequence_v2: () => editSequence('graph-v2'), stable_ids: stableIds, simple, alias_private: aliasPrivate, generic_fields: genericFields, no_eval: noEval, strict, symlinks, negative_protocol: negativeProtocol, packages, contract_surface: contractSurface, disk_revision: diskRevision, queries, projections, named_calls: namedCalls };
const filter = process.env.ANALYSIS_TEST_FILTER ? process.env.ANALYSIS_TEST_FILTER.split(',') : null;
for (const [name, test] of Object.entries(tests)) {
    if (filter && !filter.includes(name)) continue;
    await test();
    console.log('ok', name);
}
console.log('analysis graph: protocol fixtures passed');
