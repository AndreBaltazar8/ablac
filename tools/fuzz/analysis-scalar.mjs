// The editor's checked scalar bodies (#1132) against full typing, over seeded edits (#648). Each seed writes a small
// project whose dep.ab holds explicitly typed scalar functions of the shapes the replay admits (expression and block
// bodies, inferred and written locals, guard returns, the arithmetic and bit operators, parentheses, string parameters'
// size and bytes, direct calls to call-free scalar helpers in the module, a public nullary provider read by callers in
// another module), and the later slices: loop bodies (a `var` of the result type, assignments, `if`, `while`, `do … while`, `for`
// over a range with `break`/`continue`), an int array parameter's size, elements and iteration, an array of a plain class read
// through its elements' field chains, a class parameter's record-field chains, constructors of the module's plain classes and
// calls of another module's functions (lib.ab). A constructor with another class's constructor as an argument, and a chain
// through a class-typed field of an array's or a loop's element, are outside the slice (full typing): they come less often.
// It then edits one function at a time (half the edits go to those slices' functions): a new well-typed body, a literal
// changed, a local added or taken away, a type error, an unknown name, a provider whose result width or value changes, a
// helper that gains a call, and the original put back.
// Two services follow the same edits: one with ABLA_ANALYSIS_INCREMENTAL_TYPING=2 and ABLA_ANALYSIS_CHECK=1 (its own cold
// comparison after every analysis), one with replay off. After every edit their
// analyze answers, their `since` answers and definition, hover and references at each name in the edited function
// must be equal, and the replaying one must not report a difference from its cold analysis. A difference is minimised to
// the shortest edit sequence that still shows it (the failing text alone after the original, then after the text
// before it) and written to <work>/failure-<seed>/ (the texts, and the first differing path).
//
//   node tools/fuzz/analysis-scalar.mjs COMPILER --seeds A-B [--edits N] [--work DIR]
//   node tools/fuzz/analysis-scalar.mjs COMPILER --control    the replaying service is told to differ from its cold analysis
//     (ABLA_ANALYSIS_CHECK=2, the service's own self-test) on one seed: the run must report it; then, for each later slice, three
//     edits of its function must agree without the plant with at least one rechecked alone, and be reported with it
//
// It prints one line per seed and, at the end, how many edits each replay path took (rechecked one scalar body,
// rechecked an interface and dependents, a type-inert replay) and, by family, how many edits were rechecked alone, so a run
// that never reached the replay is visible: it fails when no edit of the whole run was rechecked as a scalar body.
import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import readline from 'node:readline';
import { isDeepStrictEqual } from 'node:util';
import { pathToFileURL } from 'node:url';

const argv = process.argv.slice(2);
const compiler = path.resolve(argv[0] ?? '');
let seeds = [1, 1];
let edits = 12;
let work = path.resolve('build/fuzz-analysis-scalar');
let control = false;
for (let i = 1; i < argv.length; i += 2) {
    if (argv[i] === '--control') { control = true; seeds = [1, 1]; edits = 4; i -= 1; continue; }
    if (argv[i] === '--seeds') seeds = argv[i + 1].split('-').map(Number);
    else if (argv[i] === '--edits') edits = Number(argv[i + 1]);
    else if (argv[i] === '--work') work = path.resolve(argv[i + 1]);
    else { console.error(`analysis-scalar: unknown option ${argv[i]}`); process.exit(2); }
}
if (!fs.existsSync(compiler) || !(seeds[0] <= seeds[1])) {
    console.error('usage: node tools/fuzz/analysis-scalar.mjs COMPILER --seeds A-B [--edits N] [--work DIR]');
    process.exit(2);
}
fs.mkdirSync(work, { recursive: true });
const uri = (file) => pathToFileURL(file).href;
const bytes = (text) => Buffer.byteLength(text);

// ---- the random source (xorshift32 from the seed, as tests/analysis-check/run.mjs)
let state = 1;
const random = () => {
    state ^= state << 13; state >>>= 0;
    state ^= state >>> 17;
    state ^= state << 5; state >>>= 0;
    return state / 4294967296;
};
const below = (n) => Math.floor(random() * n);
const pick = (items) => items[below(items.length)];
const chance = (p) => random() < p;

// ---- the service
class Session {
    constructor(project, env, log) { this.id = 0; this.project = project; this.env = env; this.log = path.join(project, log); }
    async start() {
        const stderr = fs.openSync(this.log, 'w');
        this.process = spawn(compiler, ['analyze', '--stdio'], { stdio: ['pipe', 'pipe', stderr], env: this.env });
        fs.closeSync(stderr);
        this.exit = new Promise((resolve) => this.process.on('close', resolve));
        this.lines = readline.createInterface({ input: this.process.stdout })[Symbol.asyncIterator]();
        await this.rpc('initialize', { workspaceRoots: [this.project], clientName: 'fuzz-analysis-scalar', clientVersion: '1',
            analysisMode: 'graph-v2', unusedImports: true });
        return this;
    }
    async rpc(method, params) {
        this.id += 1;
        this.process.stdin.write(JSON.stringify({ schema: 1, id: this.id, method, params }) + '\n');
        const next = await this.lines.next();
        if (next.done) throw new Error(`${method}: the service ended: ${fs.readFileSync(this.log, 'utf8').slice(-2000)}`);
        return JSON.parse(next.value);
    }
    async close() {
        try { await this.rpc('shutdown', {}); } catch { /* reported by the caller */ }
        this.process.stdin.end();
        return await this.exit;
    }
    stderr() { return fs.readFileSync(this.log, 'utf8'); }
}

// ---- the project and its functions
// A function: name, parameter list, result type, and its body text (after the signature: `= expr` or `{ ... }`).
const HELPERS = ['step', 'shift', 'mix'];
// The families whose slices the replay gained after the scalar forms: loops (var, assignments, if, while, do, for over a range,
// break/continue), scalar-array parameters, arrays of a class, and record-field chains with constructors and calls of another module.
const SLICES = { loopSample: 'loop', arraySample: 'array', recordSample: 'record', pairSample: 'pair' };
const initialFunctions = () => [
    { name: 'loopSample', params: 'left: int, right: int', result: 'int', body: '{\n    var s = 0\n    for (i in 0 until left) s += i\n    s + right\n}', shape: { form: 4, stmts: ['forRange'], typed: false, locals: [], brace: false, helpers: true } },
    { name: 'arraySample', params: 'left: int, right: int, xs: array<int>', result: 'int', body: '{\n    var s = xs.size\n    for (x in xs) s += x\n    s + left\n}', shape: { form: 4, stmts: ['forXs'], typed: false, locals: [], brace: false, helpers: true } },
    { name: 'recordSample', params: 'left: int, right: int, ps: array<Pair>', result: 'int', body: '{\n    var s = ps.size\n    for (e in ps) s += e.a\n    s + left\n}', shape: { form: 4, stmts: ['forPs'], typed: false, locals: [], brace: false, helpers: true } },
    { name: 'pairSample', params: 'left: int, right: int, q: Pair', result: 'int', body: '= q.inner.k + cellArea(Cell(left, right, "t")) + twice(left)', shape: { form: 0, locals: [], brace: false, helpers: true } },
    { name: 'area', params: 'q: Pair', result: 'int', body: '= q.a * q.b', shape: { form: 0, locals: [], brace: false, helpers: false } },
    { name: 'cellArea', params: 'c: Cell', result: 'int', body: '= c.a - c.b', shape: { form: 0, locals: [], brace: false, helpers: false } },
    { name: 'answer', params: 'left: int, right: int', result: 'int', body: '= left + right', shape: { form: 0, locals: [], brace: false, helpers: true } },
    { name: 'blockSample', params: 'left: int, right: int', result: 'int', body: '{\n    val t = left * 2\n    t + right\n}', shape: { form: 1, locals: [false], brace: false, helpers: true } },
    { name: 'guardSample', params: 'left: int, right: int', result: 'int', body: '{\n    if (left < 0) return right\n    left - right\n}', shape: { form: 2, locals: [], brace: false, helpers: true } },
    { name: 'textSample', params: 'left: int, right: int, text: string', result: 'int', body: '= text.size + left', shape: { form: 0, locals: [], brace: false, helpers: true } },
    { name: 'narrowSample', params: 'small: i32, other: i32', result: 'i32', body: '= small + other', shape: { form: 0, locals: [], brace: false, helpers: true } },
    { name: 'floatSample', params: 'x: f64, y: f64', result: 'f64', body: '= x * y + 0.5', shape: { form: 0, locals: [], brace: false, helpers: true } },
    { name: 'mixedSample', params: 'x: f64, n: int', result: 'f64', body: '= if (n > 0) x else -(x)', shape: { form: 0, locals: [], brace: false, helpers: true } },
    { name: 'testSample', params: 'left: int, right: int', result: 'bool', body: '= left < right', shape: { form: 0, locals: [], brace: false, helpers: true } },
    { name: 'step', params: 'n: int', result: 'int', body: '= n + 1', shape: { form: 0, locals: [], brace: false, helpers: false } },
    { name: 'shift', params: 'n: int', result: 'int', body: '= n * 2', shape: { form: 0, locals: [], brace: false, helpers: false } },
    { name: 'mix', params: 'a: int, b: int', result: 'int', body: '= (a ^ b) & 255', shape: { form: 0, locals: [], brace: false, helpers: false } },
];
const providerInitial = 'fun later(): int = 7\n';
const readerText = 'import "./provider.ab"\nfun readLater(): int = later() + 1\nfun sameLater(): bool = later() == later()\n';
const mainText = 'import "./dep.ab"\nimport "./reader.ab"\n' +
    'fun main: int = answer(2, 3) + blockSample(1, 2) + guardSample(3, 4) + textSample(1, 2, "abc") + int(narrowSample(i32(1), i32(2))) + ' +
    'step(1) + shift(2) + mix(3, 4) + readLater() + (if (sameLater()) 0 else 1) + (if (testSample(1, 2)) 1 else 0) + ' +
    '(if (floatSample(1.0, 2.0) + mixedSample(0.5, 1) > 1.0) 1 else 0) + loopSample(1, 2) + arraySample(1, 2, [1, 2, 3]) + ' +
    'recordSample(1, 2, [Pair(4, 5, Inner(1, "i"))]) + pairSample(1, 2, Pair(3, 4, Inner(2, "j"))) + cellArea(Cell(1, 2, "c"))\n';
// Another module's functions (a cross-module call is in the replay's slice) and two plain classes, one a field of the other.
const libText = 'fun twice(n: int): int = n * 2\nfun less(n: int): int = n - 1\n';
const depHead = 'import "./lib.ab"\nclass Inner(val k: int, val tag: string)\nclass Pair(val a: int, val b: int, val inner: Inner)\nclass Cell(val a: int, val b: int, val name: string)\n';
const depText = (functions) => depHead + functions.map((f) => `fun ${f.name}(${f.params}): ${f.result} ${f.body}\n`).join('');

// ---- expressions over a function's parameters
const paramNames = (f) => f.params.split(', ').map((p) => p.split(': '));
/** An expression of `ty` (int, i32, f64 or bool) over `f`'s parameters of that type and `locals` (of `f.result`'s type). */
function typedExpr(f, ty, depth, locals, helpersAllowed) {
    // A local written `e:Pair` is a loop's element of the class (read through its fields); the others are of f.result's type.
    const names = paramNames(f).filter(([, t]) => t === ty).map(([n]) => n).concat(f.result === ty ? locals.filter((l) => !l.includes(':')) : []);
    const lit = () => ty === 'i32' ? `i32(${below(300)})` : ty === 'f64' ? pick(['0.5', '1.0', '2.25', '1.0e3', '0.0', '3.0']) :
        ty === 'bool' ? pick(['true', 'false']) : `${below(1000)}`;
    if (depth <= 0 || chance(0.2)) return names.length > 0 && chance(0.6) ? pick(names) : lit();
    const d = depth - 1;
    const c = random();
    const sub = () => typedExpr(f, ty, d, locals, helpersAllowed);
    if (c < 0.10) return `(if (${typedExpr(f, 'bool', d, locals, helpersAllowed)}) ${sub()} else ${sub()})`;
    if (c < 0.18) return `(${sub()})`;
    if (ty === 'bool') {
        if (c < 0.50) {
            const side = pick(f.result === 'f64' ? ['f64', 'int'] : ['int']);
            return `${typedExpr(f, side, d, locals, helpersAllowed)} ${pick(['<', '<=', '>', '>=', '==', '!='])} ${typedExpr(f, side, d, locals, helpersAllowed)}`;
        }
        if (c < 0.75) return `${sub()} ${pick(['&&', '||'])} ${sub()}`;
        if (c < 0.85) return `!(${sub()})`;
        return pick(names.length ? names : [lit()]);
    }
    if (ty === 'f64') {
        if (c < 0.55) return `${sub()} ${pick(['+', '-', '*', '/'])} ${sub()}`;
        if (c < 0.65) return `-(${sub()})`;
        return pick(names.length ? names : [lit()]);
    }
    const one = ty === 'i32' ? 'i32(1)' : '1';
    if (c < 0.42) return `${sub()} ${pick(['+', '-', '*', '&', '|', '^'])} ${sub()}`;
    if (c < 0.50) return `(${sub()} ${pick(['/', '%'])} (${sub()} | ${one}))`;
    if (c < 0.56) return `(${sub()} ${pick(['<<', '>>', '>>>'])} ${ty === 'i32' ? 'i32(' + below(8) + ')' : below(8)})`;
    if (c < 0.62) return `-(${sub()})`;
    if (c < 0.76 && helpersAllowed && ty === 'int') {
        const helper = pick(HELPERS.filter((h) => h !== f.name));
        return helper === 'mix' ? `mix(${sub()}, ${lit()})` : `${helper}(${sub()})`;
    }
    if (c < 0.86 && f.params.includes('text: string') && ty === 'int') return chance(0.5) ? 'text.size' : `text[${pick(['0', '1', 'left % 3', '(right & 1)'])}]`;
    if (c < 0.95 && ty === 'int') {
        const atoms = memberAtoms(f, sub, locals, helpersAllowed);
        if (atoms.length > 0) return pick(atoms)();
    }
    return pick(names.length ? names : [lit()]);
}

/** Int expressions of the newer slices that `f` can write: field chains of a Pair (a parameter, an array's element, a loop's
 *  element), an int array's size and elements, a Pair built and passed to `area`, and calls of lib.ab's functions. */
function memberAtoms(f, sub, locals, helpersAllowed) {
    const atoms = [];
    const pairs = paramNames(f).filter(([, t]) => t === 'Pair').map(([n]) => n)
        .concat(locals.filter((l) => l.endsWith(':Pair')).map((l) => l.split(':')[0]));
    if (paramNames(f).some(([n, t]) => n === 'ps' && t === 'array<Pair>')) {
        atoms.push(() => 'ps.size');
        pairs.push(`ps[${pick(['0', 'left % ps.size', '(right & 0)'])}]`);
    }
    // A chain through `inner` from an array's element or a loop's is not in the slice (full typing): one draw in four of those.
    for (const p of pairs) {
        const direct = !p.includes('[') && paramNames(f).some(([n]) => n === p);
        atoms.push(() => `${p}.${pick(['a', 'b'])}`,
            () => (direct || chance(0.25) ? `${p}.${pick(['inner.k', 'inner.tag.size'])}` : `${p}.${pick(['a', 'b'])}`));
        if (helpersAllowed && f.name !== 'area') atoms.push(() => `area(${p})`);
    }
    for (const [n, t] of paramNames(f)) {
        if (t === 'Cell') atoms.push(() => `${n}.${pick(['a', 'b', 'name.size'])}`);
    }
    if (paramNames(f).some(([n, t]) => n === 'xs' && t === 'array<int>')) atoms.push(() => 'xs.size', () => `xs[${sub()}]`);
    // Constructors: of a class of scalar and string fields (in the slice), or now and then a class whose field is another class's
    // constructor call (full typing).
    if (helpersAllowed && f.name !== 'area' && f.name !== 'cellArea') {
        atoms.push(() => `${pick(['twice', 'less'])}(${sub()})`,
            () => (chance(0.75) ? `cellArea(Cell(${sub()}, ${sub()}, ${pick(['"t"', '"tag"', '""'])}))`
                : `area(Pair(${sub()}, ${sub()}, Inner(${sub()}, ${pick(['"t"', '"tag"', '""'])})))`));
    }
    return atoms;
}
const intExpr = (f, depth, locals, helpersAllowed) => typedExpr(f, f.result, depth, locals, helpersAllowed);
/** A guard's condition. */
const boolExpr = (f, locals) => typedExpr(f, 'bool', 2, locals, false);

/** A body's shape: its form (0 `= expr`, 1 a block, 2 a block with a guard return, 3 that and a final `return`), its locals
 *  (whether each has a written type), and the guard's braces. Edits that keep a shape change only expressions: the
 *  replay needs the same symbols (locals are symbols). */
function newShape(f) {
    // Form 4, a loop body (a `var s` of the result type, one to three statements over it, then a result), for int functions: the
    // loop families mostly, the others now and then.
    if (f.result === 'int' && !HELPERS.includes(f.name) && f.name !== 'area' && f.name !== 'cellArea' && chance(f.name in SLICES && f.name !== 'pairSample' ? 0.8 : 0.15)) {
        const kinds = ['forRange', 'forRangeControl', 'while', 'do', 'if', 'assign'];
        if (f.params.includes('xs: array<int>')) kinds.push('forXs', 'forXs');
        if (f.params.includes('ps: array<Pair>')) kinds.push('forPs', 'forPs', 'forPsIf');
        return { form: 4, stmts: Array.from({ length: 1 + below(3) }, () => pick(kinds)), typed: chance(0.3), locals: [], brace: chance(0.5), helpers: true };
    }
    const form = below(4);
    const locals = form > 0 ? Array.from({ length: below(3) }, () => chance(0.4)) : [];
    return { form, locals, brace: chance(0.5), helpers: !HELPERS.includes(f.name) || chance(0.2) };
}

/** A new body for `f` of `shape` (a new shape when none), well typed unless `broken` names how not to be. */
function newBody(f, broken, shape = newShape(f)) {
    if (shape.form === 4) return loopBody(f, broken, shape);
    const helpersAllowed = shape.helpers;   // a helper that calls another is no longer call-free
    const locals = [];
    const lines = [];
    const form = shape.form;
    if (form > 0) {
        shape.locals.forEach((typedLocal, k) => {
            const name = `t${k}`;
            const typed = typedLocal ? `: ${f.result}` : '';
            lines.push(`val ${name}${typed} = ${intExpr(f, 2, locals, helpersAllowed)}`);
            locals.push(name);
        });
        if (form >= 2) lines.push(`if (${boolExpr(f, locals)}) ${shape.brace ? '{ return ' + intExpr(f, 2, locals, helpersAllowed) + ' }' : 'return ' + intExpr(f, 2, locals, helpersAllowed)}`);
    }
    let result = intExpr(f, 3, locals, helpersAllowed);
    if (broken === 'type') result = pick([`${result} + true`, `"x"`, `${result} + "y"`, 'true']);
    if (broken === 'unknown') result = pick([`${result} + missingName`, `missingCall(${result})`]);
    if (broken === 'local') { lines.unshift(`val ${paramNames(f)[0][0]} = 1`); }
    // An expression body that ends in `)` never replays (its parsed expression ends before the closing parenthesis, so the text after
    // the body differs): most end on an operand so that the replay is reached, a quarter keep the parenthesis.
    const tail = f.result === 'f64' ? ' + 0.0' : f.result === 'bool' ? ' || false' : f.result === 'i32' ? ' + i32(0)' : ' + 0';
    if (lines.length === 0 && form === 0) return `= ${result.endsWith(')') && chance(0.75) ? result + tail : result}`;
    if (form === 3 && shape.brace) lines.push(`return ${result}`); else lines.push(result);
    return '{\n' + lines.map((line) => '    ' + line + '\n').join('') + '}';
}

/** A loop body of `shape` (form 4): `var s`, the statements its `stmts` name, and a result over `s`. A loop's variable is in scope
 *  in its own body only; `broken` "unknown" reads it after the loop (there is no global `i`), "type" adds a bool, "assign" makes
 *  `s` a `val` that a statement assigns. */
function loopBody(f, broken, shape) {
    const h = shape.helpers;
    const locals = [];
    const e = (depth, extra = []) => intExpr(f, depth, locals.concat(extra), h);
    const test = (extra = []) => typedExpr(f, 'bool', 1, locals.concat(extra), h);
    const lines = [`${broken === 'assign' ? 'val' : 'var'} s${shape.typed ? ': int' : ''} = ${e(2)}`];
    locals.push('s');
    for (const kind of shape.stmts) {
        if (kind === 'forRange') lines.push(`for (i in ${e(1)} ${pick(['until', '..'])} ${e(1)}) s ${pick(['+=', '-=', '*=', '='])} ${e(2, ['i'])}`);
        else if (kind === 'forRangeControl') {
            lines.push(`for (i in ${e(1)}..${e(1)}) {`, `    if (${test(['i'])}) continue`, `    s = s + ${e(2, ['i'])}`,
                `    if (s > ${below(1000)}) break`, '}');
        } else if (kind === 'while') lines.push(`while (s > ${e(1)}) s -= ${1 + below(9)}`);
        else if (kind === 'do') lines.push(`do { s += ${e(1)} } while (s < ${e(1)})`);
        else if (kind === 'if') lines.push(`if (${test()}) s = ${e(2)}${chance(0.5) ? ` else s += ${e(1)}` : ''}`);
        else if (kind === 'assign') lines.push(`s ${pick(['+=', '-=', '*=', '='])} ${e(2)}`);
        else if (kind === 'forXs') lines.push(`for (x in xs) s += ${e(2, ['x'])}`);
        else if (kind === 'forPs') lines.push(`for (e in ps) s += ${e(2, ['e:Pair'])}`);
        else lines.push(`for (e in ps) if (${test(['e:Pair'])}) s += 1`);
    }
    let result = e(2);
    if (broken === 'type') result = pick([`${result} + true`, `"x"`, 'true']);
    if (broken === 'unknown') result = pick([`${result} + missingName`, 's + i', `missingCall(${result})`]);
    if (broken === 'local') lines.unshift(`val ${paramNames(f)[0][0]} = 1`);
    lines.push(shape.brace ? `return ${result}` : result);
    return '{\n' + lines.map((line) => '    ' + line + '\n').join('') + '}';
}

/** A literal in the body changed, if it has one. */
function changeLiteral(body) {
    const literals = [...body.matchAll(/(?<![A-Za-z_0-9])\d+(?![A-Za-z_0-9])/g)];
    if (literals.length === 0) return null;
    const chosen = pick(literals);
    return body.slice(0, chosen.index) + String((Number(chosen[0]) + 1 + below(50)) % 1000) + body.slice(chosen.index + chosen[0].length);
}

// ---- comparison
function firstDifference(a, b, where = '') {
    if (isDeepStrictEqual(a, b)) return null;
    if (typeof a !== 'object' || typeof b !== 'object' || a === null || b === null || Array.isArray(a) !== Array.isArray(b))
        return `${where || '(top)'}: ${JSON.stringify(a)?.slice(0, 300)} vs ${JSON.stringify(b)?.slice(0, 300)}`;
    const keys = new Set([...Object.keys(a), ...Object.keys(b)]);
    for (const key of keys) {
        const found = firstDifference(a[key], b[key], `${where}/${key}`);
        if (found) return found;
    }
    return `${where}: differs`;
}

const counts = { scalar: 0, interface: 0, inert: 0, analyses: 0 };
// By step family (SLICES, 'loop' for a loop body elsewhere, 'scalar'): edits, and edits the replay rechecked as one scalar body.
const families = {};
// The families the last sequence rechecked, whether tallied or not (the controls read it).
let lastRechecked = {};

/** Runs one sequence of (file, text) edits through both services; the first difference found, or null. */
async function runSequence(project, steps, tally, plant = control) {
    const trace = { ...process.env, ABLA_ANALYSIS_INCREMENTAL_TRACE: '1' };
    delete trace.ABLA_ANALYSIS_INCREMENTAL_TYPING;
    delete trace.ABLA_ANALYSIS_CHECK;
    const replay = await new Session(project, { ...trace, ABLA_ANALYSIS_INCREMENTAL_TYPING: '2', ABLA_ANALYSIS_CHECK: plant ? '2' : '1' }, 'replay.stderr').start();
    const full = await new Session(project, { ...trace, ABLA_ANALYSIS_INCREMENTAL_TYPING: '0', ABLA_ANALYSIS_CHECK: '0' }, 'full.stderr').start();
    const sessions = [replay, full];
    const versions = new Map();
    let revision;
    let problem = null;
    let seen = 0;
    let rechecks = 0;
    lastRechecked = {};
    try {
        for (let at = 0; at <= steps.length && problem === null; at++) {
            if (at > 0) {
                const { file, text } = steps[at - 1];
                const version = (versions.get(file) ?? 0) + 1;
                versions.set(file, version);
                for (const s of sessions) {
                    const answer = await s.rpc(version === 1 ? 'document/open' : 'document/change', { uri: uri(file), version, text });
                    if ('error' in answer) { problem = `step ${at}: ${JSON.stringify(answer.error)}`; break; }
                }
                if (problem) break;
            }
            const [actual, expected] = await Promise.all(sessions.map((s) => s.rpc('analyze', {})));
            counts.analyses += tally ? 1 : 0;
            // the replay's trace line for this step (written while it answered `analyze`)
            const now = (replay.stderr().match(/rechecked one scalar body/g) ?? []).length;
            if (at > 0) {
                const family = steps[at - 1].family ?? 'scalar';
                if (now > rechecks) lastRechecked[family] = (lastRechecked[family] ?? 0) + 1;
                if (tally) {
                    families[family] ??= { edits: 0, rechecked: 0 };
                    families[family].edits += 1;
                    if (now > rechecks) families[family].rechecked += 1;
                }
            }
            rechecks = now;
            const difference = firstDifference(actual, expected);
            if (difference) { problem = `step ${at}: analyze ${difference}`; break; }
            if (revision !== undefined) {
                const [delta, ref] = await Promise.all(sessions.map((s) => s.rpc('analyze', { since: revision })));
                const d = firstDifference(delta, ref);
                if (d) { problem = `step ${at}: since ${d}`; break; }
            }
            revision = actual.result?.revision;
            // queries at each name of the edited text (or of dep.ab at the start)
            const file = at > 0 ? steps[at - 1].file : path.join(project, 'dep.ab');
            const text = at > 0 ? steps[at - 1].text : fs.readFileSync(file, 'utf8');
            const names = [...text.matchAll(/[A-Za-z_][A-Za-z_0-9]*/g)].filter((m) => !/^(fun|val|var|if|else|return|int|i32|string|bool|true|false|import|class|for|in|until|while|do|break|continue)$/.test(m[0]));
            const chosen = names.length <= 6 ? names : Array.from({ length: 6 }, () => pick(names));
            for (const name of chosen) {
                const editor = { uri: uri(file), offset: bytes(text.slice(0, name.index)), revision };
                for (const method of ['query/definition', 'query/hover', 'query/references']) {
                    const [found, ref] = await Promise.all(sessions.map((s) => s.rpc(method, editor)));
                    const d = firstDifference(found, ref);
                    if (d) { problem = `step ${at}: ${method} at ${name[0]}@${editor.offset}: ${d}`; break; }
                }
                if (problem) break;
            }
            const log = replay.stderr();
            if (process.env.ANALYSIS_SCALAR_DEBUG === '1') {
                const traced = log.split('\n').filter((line) => /rechecked|replayed|fallback/.test(line));
                console.log(`  step ${at} ${at > 0 ? steps[at - 1].label : 'start'}: ${traced.length > seen ? traced.slice(seen).join('; ') : '(no replay line)'}`);
                seen = traced.length;
            }
            const reported = log.split('\n').find((line) => /abla-analysis-check.*(?:DIFFERENT|FAILED)/.test(line));
            if (reported) { problem = `step ${at}: the replaying service differs from its cold analysis: ${reported}`; break; }
        }
    } catch (error) {
        problem = `exception: ${error.message.slice(0, 500)}`;
    } finally {
        const statuses = await Promise.all(sessions.map((s) => s.close()));
        if (problem === null && statuses.some((s) => s !== 0)) problem = `a service exited ${statuses.join('/')}`;
    }
    if (tally) {
        const log = replay.stderr();
        counts.scalar += (log.match(/rechecked one scalar body/g) ?? []).length;
        counts.interface += (log.match(/rechecked scalar interface and dependents/g) ?? []).length;
        counts.inert += (log.match(/replayed a type-inert body edit/g) ?? []).length;
    }
    return problem;
}

function writeProject(directory, functions) {
    fs.rmSync(directory, { recursive: true, force: true });
    fs.mkdirSync(directory, { recursive: true });
    fs.writeFileSync(path.join(directory, 'abla.toml'), 'name = "fuzz-analysis-scalar"\nentry = "main.ab"\nvisibility = "imports"\n');
    fs.writeFileSync(path.join(directory, 'main.ab'), mainText);
    fs.writeFileSync(path.join(directory, 'reader.ab'), readerText);
    fs.writeFileSync(path.join(directory, 'provider.ab'), providerInitial);
    fs.writeFileSync(path.join(directory, 'lib.ab'), libText);
    fs.writeFileSync(path.join(directory, 'dep.ab'), depText(functions));
}

/** The seed's edit sequence: each step the whole text of dep.ab or provider.ab. */
function makeSteps(project, count) {
    const original = initialFunctions();
    let functions = initialFunctions();
    let provider = providerInitial;
    const steps = [];
    for (let i = 0; i < count; i++) {
        const kind = random();
        if (kind < 0.12) {
            provider = pick(['fun later(): int = 7\n', 'fun later(): int = 8\n', 'fun later(): int = 2+2\n', 'fun later(): i32 = i32(7)\n',
                'fun later(): i64 = 7\n', 'fun later(): i64 = 2+2\n', 'fun later(): i64 = 7\n', 'fun later(): int = 7\n',
                'fun later(): int = 7 * 3\n', 'fun later(): bool = true\n', 'fun later(): int = missing\n']);
            steps.push({ file: path.join(project, 'provider.ab'), text: provider, label: `provider ${provider.trim()}`, family: 'provider' });
            // a provider its readers cannot use is put right in the next step: an answer with errors sends every later edit to full typing
            if (/bool|missing/.test(provider)) {
                provider = providerInitial;
                steps.push({ file: path.join(project, 'provider.ab'), text: provider, label: 'provider repaired', family: 'provider' });
            }
            continue;
        }
        // half the edits go to the newer slices' functions
        const sliced = functions.map((g, k) => (g.name in SLICES ? k : -1)).filter((k) => k >= 0);
        const at = chance(0.5) ? pick(sliced) : below(functions.length);
        const f = functions[at];
        let body;
        let shape = f.shape;
        const label = `${kind < 0.55 ? 'expressions' : kind < 0.65 ? 'literal' : kind < 0.72 ? 'shape' : kind < 0.76 ? 'type-error' : kind < 0.80 ? 'unknown' : kind < 0.83 ? 'shadow' : kind < 0.92 ? 'revert' : 'parens'}:${f.name}`;
        // most edits keep the shape and change expressions (what the replay admits); the rest make it type again
        if (kind < 0.55) body = newBody(f, null, shape);
        else if (kind < 0.65) body = changeLiteral(f.body) ?? newBody(f, null, shape);
        else if (kind < 0.72) { shape = newShape(f); body = newBody(f, null, shape); }
        else if (kind < 0.76) body = newBody(f, shape.form === 4 && chance(0.4) ? 'assign' : 'type', shape);
        else if (kind < 0.80) body = newBody(f, 'unknown', shape);
        else if (kind < 0.83) { shape = { ...shape, form: Math.max(shape.form, 1) }; body = newBody(f, 'local', shape); }
        else if (kind < 0.92) { shape = original[at].shape; body = original[at].body; }
        else body = f.body.startsWith('= ') ? `= (${f.body.slice(2)})` : f.body + ' // trailing';
        const before = functions;
        functions = functions.map((g, k) => (k === at ? { ...g, body, shape } : g));
        steps.push({ file: path.join(project, 'dep.ab'), text: depText(functions), label: `${label} ${body.replace(/\n\s*/g, ' ')}`, family: SLICES[f.name] ?? (shape.form === 4 ? 'loop' : 'scalar') });
        // an error is put right in the next step, as an editor user does (and so the edits after it can replay again)
        if (/^(type-error|unknown|shadow)/.test(label)) {
            functions = before;
            steps.push({ file: path.join(project, 'dep.ab'), text: depText(functions), label: `repaired:${f.name}`, family: 'repair' });
        }
    }
    return steps;
}

/** `count` edits of function `name` that keep its first shape and change its expressions (what the replay admits). */
function sliceSteps(project, name, count) {
    let functions = initialFunctions();
    const steps = [];
    for (let i = 0; i < count; i++) {
        functions = functions.map((g) => (g.name === name ? { ...g, body: newBody(g, null, g.shape) } : g));
        steps.push({ file: path.join(project, 'dep.ab'), text: depText(functions), label: `expressions:${name}`, family: SLICES[name] });
    }
    return steps;
}

let failed = 0;
for (let seed = seeds[0]; seed <= seeds[1]; seed++) {
    state = (seed * 2654435761) >>> 0 || 1;
    const project = path.join(work, `seed${seed}`);
    writeProject(project, initialFunctions());
    const steps = makeSteps(project, edits);
    const problem = await runSequence(project, steps, true);
    if (problem === null) { console.log(`seed ${seed}: ${steps.length} edits agree`); continue; }
    failed += 1;
    // the failing step, then the shortest sequence that still differs
    const failing = Number(/^step (\d+)/.exec(problem)?.[1] ?? steps.length);
    let kept = steps.slice(0, failing);
    for (const candidate of [kept.slice(-1), kept.slice(-2)]) {
        if (candidate.length === 0 || candidate.length >= kept.length) continue;
        writeProject(project, initialFunctions());
        if (await runSequence(project, candidate, false) !== null) { kept = candidate; break; }
    }
    const out = path.join(work, `failure-${seed}`);
    fs.rmSync(out, { recursive: true, force: true });
    fs.mkdirSync(out, { recursive: true });
    writeProject(path.join(out, 'project'), initialFunctions());
    kept.forEach((step, k) => fs.writeFileSync(path.join(out, `step${k + 1}-${path.basename(step.file)}`), step.text));
    fs.writeFileSync(path.join(out, 'problem.txt'), problem + '\n');
    console.log(`seed ${seed}: DIFFERS ${problem.slice(0, 400)}`);
    console.log(`  kept ${kept.length} of ${steps.length} edits in ${out}`);
}
console.log(`analysis-scalar: ${counts.analyses} analyses; replay rechecked ${counts.scalar} scalar bodies, ${counts.interface} interfaces with dependents, ${counts.inert} type-inert edits; ${failed} seeds differ`);
console.log(`analysis-scalar: rechecked alone, by family: ${Object.entries(families).map(([name, n]) => `${name} ${n.rechecked}/${n.edits}`).join(', ')}`);
if (control) {
    if (failed === 0) { console.error('analysis-scalar: control: a planted difference was not reported'); process.exit(1); }
    console.log('analysis-scalar: control: a planted difference is reported');
    // Each newer slice: three edits of its function that keep the body's shape. Without the plant they agree with full typing and
    // the replay rechecks at least one alone (so the slice is reached); with it, the difference is reported at that edit.
    for (const [name, family] of Object.entries(SLICES)) {
        state = 0x9e3779b9;
        const project = path.join(work, `control-${family}`);
        writeProject(project, initialFunctions());
        const steps = sliceSteps(project, name, 3);
        const clean = await runSequence(project, steps, false, false);
        if (clean !== null) { console.error(`analysis-scalar: control: ${family} edits differ without the plant: ${clean.slice(0, 400)}`); process.exit(1); }
        if (!(lastRechecked[family] > 0)) { console.error(`analysis-scalar: control: no ${family} edit was rechecked alone (the slice is not reached)`); process.exit(1); }
        writeProject(project, initialFunctions());
        const planted = await runSequence(project, steps, false, true);
        if (planted === null) { console.error(`analysis-scalar: control: a planted difference in a ${family} edit was not reported`); process.exit(1); }
    }
    console.log(`analysis-scalar: control: ${Object.values(SLICES).join(', ')} edits are rechecked alone and a planted difference in each is reported`);
    process.exit(0);
}
if (counts.scalar === 0) { console.error('analysis-scalar: no edit was rechecked as a scalar body (the run reached nothing)'); process.exit(1); }
process.exit(failed > 0 ? 1 : 0);
