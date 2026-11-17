// The documentation module of the language's built-ins (stdlib/abla/builtins/declarations.ab) against the compiler. Usage: node check.mjs COMPILER
//
// - every member the module declares on a built-in receiver is accepted by sema on a value of that type (a probe program per receiver);
// - every member name sema's branches mention (mined from src/sema.ab) that the module does not declare is rejected by sema: a built-in
//   member added to sema without a declaration here fails this test, and so does a declaration of something sema does not have;
// - the module's types are the ones docs/language.md's table of types lists (the library's own types excepted), and each is accepted
//   as the type of a parameter.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { fileURLToPath } from 'node:url';

const compiler = path.resolve(process.argv[2]);
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const scratch = path.resolve('build/builtin-docs');
fs.rmSync(scratch, { recursive: true, force: true });
fs.mkdirSync(scratch, { recursive: true });

async function analyze(files, entry = 'main.ab') {
    const dir = fs.mkdtempSync(path.join(scratch, 'p-'));
    fs.writeFileSync(path.join(dir, 'abla.toml'), `name = "probe"\nentry = "${entry}"\n`);
    for (const [name, text] of Object.entries(files)) fs.writeFileSync(path.join(dir, name), text);
    const child = spawn(compiler, ['analyze', '--stdio'], { stdio: ['pipe', 'pipe', 'inherit'], env: { ...process.env, ABLA_SYSROOT: root } });
    const lines = readline.createInterface({ input: child.stdout })[Symbol.asyncIterator]();
    let id = 0;
    const rpc = async (method, params) => {
        id += 1;
        child.stdin.write(JSON.stringify({ schema: 1, id, method, params }) + '\n');
        return JSON.parse((await lines.next()).value);
    };
    await rpc('initialize', { workspaceRoots: [dir], clientName: 'builtin-docs', clientVersion: '1', analysisMode: 'graph-v2' });
    const answer = (await rpc('analyze', { roots: [path.join(dir, entry)] })).result;
    await rpc('shutdown', {});
    child.stdin.end();
    return answer;
}

// 1. what the module declares
const probeFiles = { 'main.ab': 'fun main: int = 0\n' };
const answer = await analyze(probeFiles);
const stubDocument = answer.documents.find((d) => d.uri.endsWith('/stdlib/abla/builtins/declarations.ab'));
assert.ok(stubDocument, 'the service adds the documentation module to an answer');
assert.deepEqual(stubDocument.diagnostics, [], 'the documentation module parses without diagnostics');
const text = Buffer.from(stubDocument.text);
const symbols = stubDocument.symbols;
const classes = symbols.filter((s) => s.kind === 'class' && s.topLevel);
const stub = new Map();
for (const c of classes) {
    const members = [];
    for (const s of symbols) {
        if (s.containerId !== c.id) continue;
        if (s.kind === 'function') {
            const source = text.slice(s.range.start, s.range.end).toString();
            const match = /\(([^)]*)\)/.exec(source.replace(/\(T\) -> R/g, 'FN'));
            const parameters = match && match[1].trim() !== '' ? match[1].split(',').map((p) => p.split(':')[1].trim()) : [];
            members.push({ name: s.name, property: false, parameters });
        } else if (s.kind === 'property') {
            members.push({ name: s.name, property: true, parameters: [] });
        }
    }
    stub.set(c.name, members);
}
assert.ok(stub.size >= 20, `the documentation module declares the built-in types (${stub.size})`);

// 2. the receivers
const prelude = 'resource class Conn(val id: int)\n';
const receivers = {
    array: ['array<int>', 'val x: array<int> = []', { T: '1' }],
    string: ['string', 'val x = "abc"', {}],
    Map: ['Map<string, int>', 'val x: Map<string, int> = Map()', { K: '"k"', V: '1' }],
    Cell: ['Cell<int>', 'val x: Cell<int> = Cell(1)', { T: '1' }],
    Mutex: ['Mutex<Conn>', 'val x: Mutex<Conn> = Mutex(Conn(1))', { T: 'Conn(1)', FN: '{ c -> 1 }' }],
    Shared: ['Shared<Conn>', 'val x: Shared<Conn> = Shared(Conn(1))', { T: 'Conn(1)' }],
    Weak: ['Weak<Conn>', 'val s: Shared<Conn> = Shared(Conn(1))\n    val x: Weak<Conn> = s.downgrade()', {}],
};
const argument = (type, bindings) => {
    if (type in bindings) return bindings[type];
    if (type === 'int') return '0';
    if (type === 'string') return '"s"';
    if (type === 'bool') return 'true';
    throw new Error(`no argument for a parameter of type ${type}`);
};

// the candidate names: what sema's member branches mention, and the usual suspects
const sema = fs.readFileSync(path.join(root, 'src/sema.ab'), 'utf8');
const candidates = new Set(['length', 'count', 'push', 'pop', 'first', 'last', 'contains', 'indexOf', 'isEmpty', 'insert', 'toString', 'copy', 'put', 'add', 'delete', 'find']);
const regions = [['fun bootstrapInferMemberCall(', 'fun bootstrapInferMemberAssign('], ['fun bootstrapInferMember(', 'fun bootstrapInferMemberCall('], ['    fun inferMapCall(', '    /** An untyped array literal']];
for (const [from, to] of regions) {
    const begin = sema.indexOf(from);
    assert.ok(begin >= 0, `sema.ab still has ${from}`);
    const end = sema.indexOf(to, begin + from.length);
    for (const m of sema.slice(begin, end < 0 ? sema.length : end).matchAll(/expression\.text (?:==|!=) "([a-zA-Z][a-zA-Z0-9]*)"/g)) candidates.add(m[1]);
}
const mapMethods = /fun bootstrapIsMapBuiltinMethod\(name: string\): bool =([^]*?)\n\n/.exec(sema);
assert.ok(mapMethods, 'sema.ab still lists the map built-ins');
for (const m of mapMethods[1].matchAll(/"([a-z]+)"/g)) candidates.add(m[1]);
for (const keyword of ['var', 'val', 'fun', 'class', 'if', 'else', 'for', 'while', 'return', 'this', 'null', 'true', 'false', 'when', 'in', 'is', 'as', 'do', 'break', 'continue', 'type', 'interface', 'import']) candidates.delete(keyword);

const unknownMessage = /method\.unknown|map\.member|cell\.member|mutex\.member|shared\.member|weak\.member|(^|[^a-z])member:/;
async function probe(kind, statements) {
    const [, declaration, bindings] = receivers[kind];
    void bindings;
    let source = `${prelude}fun main: int {\n    ${declaration}\n`;
    const first = source.split('\n').length - 1;
    source += statements.map((s) => `    ${s.text}\n`).join('') + '    return 0\n}\n';
    const result = await analyze({ 'main.ab': source });
    const main = result.documents.find((d) => d.uri.endsWith('/main.ab'));
    const rejected = new Set();
    const other = [];
    for (const diagnostic of main.diagnostics) {
        const line = source.slice(0, diagnostic.range?.start ?? 0).split('\n').length - 1 - first;
        const message = diagnostic.message ?? '';
        if (unknownMessage.test(message)) {
            if (line >= 0 && line < statements.length) rejected.add(statements[line].key);
            else {
                // a diagnostic without a useful position: match the member's name in the message
                const name = /[.:]([A-Za-z0-9]+)(@|$)/.exec(message)?.[1];
                for (const s of statements) if (s.name === name) rejected.add(s.key);
            }
        } else other.push(message);
    }
    return { rejected, other };
}

const problems = [];
for (const kind of Object.keys(receivers)) {
    assert.ok(stub.has(kind), `the documentation module declares ${kind}`);
    const [, , bindings] = receivers[kind];
    const declared = stub.get(kind);
    const statements = [];
    for (const member of declared) {
        if (member.property) statements.push({ key: `declared:${member.name}`, name: member.name, text: `val p_${member.name} = x.${member.name}` });
        else statements.push({ key: `declared:${member.name}`, name: member.name, text: `x.${member.name}(${member.parameters.map((p) => argument(p, bindings)).join(', ')})` });
    }
    const names = new Set(declared.map((m) => m.name));
    for (const name of candidates) {
        if (names.has(name)) continue;
        statements.push({ key: `undeclared:call:${name}`, name, text: `x.${name}()` });
        statements.push({ key: `undeclared:property:${name}`, name, text: `val q_${name} = x.${name}` });
    }
    const { rejected, other } = await probe(kind, statements);
    for (const member of declared) {
        if (rejected.has(`declared:${member.name}`)) problems.push(`${kind}.${member.name} is declared in the documentation module but the compiler rejects it`);
    }
    for (const name of candidates) {
        if (names.has(name)) continue;
        if (!rejected.has(`undeclared:call:${name}`) || !rejected.has(`undeclared:property:${name}`)) {
            problems.push(`${kind}.${name} is accepted by the compiler (as a ${rejected.has(`undeclared:call:${name}`) ? 'property' : 'call'}) but not declared in the documentation module`);
        }
    }
    void other;
}

// 3. the types
const language = fs.readFileSync(path.join(root, 'docs/language.md'), 'utf8');
const table = language.slice(language.indexOf('## Types'), language.indexOf('### Integers'));
const documented = new Set();
for (const row of table.split('\n')) {
    if (!row.startsWith('| `')) continue;
    for (const m of row.split('|')[1].matchAll(/`([A-Za-z][A-Za-z0-9]*)(?:<[^`]*>)?`/g)) documented.add(m[1]);
}
const library = new Set(['uint256', 'int256', 'uint128', 'int128']);
const extra = new Set(['Cell', 'Mutex', 'Shared', 'Weak', 'int', 'Fn', 'FnMut', 'FnOnce', 'FnNoEscape']);
// written with a signature (`FnMut(A) -> R`), so not a parameter type on its own
const bare = new Set(['Fn', 'FnMut', 'FnOnce', 'FnNoEscape']);
for (const name of documented) {
    if (library.has(name) || name === 'T' || name === 'A' || name === 'B' || name === 'R') continue;
    if (!stub.has(name)) problems.push(`docs/language.md lists the type ${name}, the documentation module does not declare it`);
}
for (const name of stub.keys()) {
    if (!documented.has(name) && !extra.has(name)) problems.push(`the documentation module declares ${name}, which docs/language.md's table of types does not list`);
}
const generic = { array: 'array<int>', Map: 'Map<string, int>', Cell: 'Cell<int>', Mutex: 'Mutex<Conn>', Shared: 'Shared<Conn>', Weak: 'Weak<Conn>' };
const typeStatements = [...stub.keys()].filter((name) => !bare.has(name)).map((name, index) => ({ key: name, name, text: `fun take${index}(a: ${generic[name] ?? name}): void {}` }));
{
    let source = prelude + typeStatements.map((s) => s.text).join('\n') + '\nfun main: int = 0\n';
    const result = await analyze({ 'main.ab': source });
    const main = result.documents.find((d) => d.uri.endsWith('/main.ab'));
    for (const d of main.diagnostics) problems.push(`a built-in type of the documentation module is not accepted as a parameter type: ${d.message}`);
}

if (problems.length > 0) {
    console.error(`builtin-docs: ${problems.length} problem(s)\n  ` + problems.join('\n  '));
    process.exit(1);
}
let members = 0;
for (const m of stub.values()) members += m.length;
console.log(`builtin-docs: ${stub.size} built-in types and ${members} members agree with the compiler (${candidates.size} candidate names probed on ${Object.keys(receivers).length} receivers)`);
