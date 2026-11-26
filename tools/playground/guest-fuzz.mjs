// Fuzzes the browser playground's compiled guest (src/backend/wasm/playground.ab): random programs inside the emitter's subset (an
// integer main with locals, + - * and comparisons, if/else, counted while loops, literal println) and just outside it, run through the
// browser compiler (compileGuest) and the guest (runGuest), with every module that comes out checked by WebAssembly.validate.
//   node guest-fuzz.mjs <browser-frontend.wasm> <repository root> [programs, default 200] [seed, default 1] [CLI compiler] [CLI programs]
// Oracles: an independent BigInt model of the subset (64-bit wrapping, as the language's int) for every program inside it, and, with a
// CLI compiler (and wasmtime), the CLI's WASI build for the first CLI programs inside the subset and for every program outside it:
// a program the guest accepts must print what the CLI prints and exit with the CLI's status (the status modulo 256, as an operating
// system reports it); a program it refuses must say so (E_PLAYGROUND_WASM_UNSUPPORTED) and produce no module.
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { boundedCompiler, compileGuest, createBase } from "./host.mjs";
import { runGuest } from "./guest.mjs";

const [wasmPath, root, countText, seedText, cliCompiler, cliCountText] = process.argv.slice(2);
const count = Number(countText ?? 200);
let seed = Number(seedText ?? 1) >>> 0;
const cliCount = Number(cliCountText ?? 30);
const random = () => {
    // xorshift32: the same programs for the same seed.
    seed ^= seed << 13; seed >>>= 0;
    seed ^= seed >>> 17;
    seed ^= seed << 5; seed >>>= 0;
    return seed / 4294967296;
};
const pick = (list) => list[Math.floor(random() * list.length)];
const wrap = (value) => BigInt.asIntN(64, value);

const module = await WebAssembly.compile(readFileSync(wasmPath));
const stdlib = new Map();
const walk = (directory) => {
    for (const entry of readdirSync(directory, { withFileTypes: true })) {
        const path = join(directory, entry.name);
        if (entry.isDirectory()) walk(path);
        else if (entry.name.endsWith(".ab") || entry.name.endsWith(".toml")) stdlib.set(relative(join(root, "stdlib"), path), readFileSync(path));
    }
};
walk(join(root, "stdlib"));
const base = createBase(stdlib);
const bounded = await boundedCompiler(readFileSync(wasmPath));
const scratch = mkdtempSync(join(tmpdir(), "guest-fuzz-"));

const constants = ["0", "1", "2", "3", "7", "63", "64", "65", "127", "128", "255", "256", "8191", "65535", "65536", "2147483647", "2147483648",
    "4294967295", "4294967296", "4294967301", "4611686018427387904", "9223372036854775807", "(0 - 1)", "(0 - 64)", "(0 - 129)",
    "(0 - 2147483648)", "(0 - 9223372036854775807)", "(0 - 9223372036854775807 - 1)"];
const literals = ["hi", "", "a b", "é→✓", "x".repeat(300), "tab\\there", "quote\\\"d", "line\\nbreak", "$$", "100%"];
const names = ["a", "b", "c", "d"];

// An expression is { text, value(env) }.
function expression(depth) {
    const roll = random();
    if (depth <= 0 || roll < 0.3) {
        if (random() < 0.5) {
            const text = pick(constants);
            return { text, eval: () => constantValue(text) };
        }
        const name = pick(names);
        return { text: name, eval: (env) => env[name] };
    }
    const operator = pick(["+", "-", "*"]);
    const left = expression(depth - 1);
    const right = expression(depth - 1);
    return {
        text: `(${left.text} ${operator} ${right.text})`,
        eval: (env) => {
            const x = left.eval(env), y = right.eval(env);
            return wrap(operator === "+" ? x + y : operator === "-" ? x - y : x * y);
        },
    };
}
function constantValue(text) {
    const match = /^\(0 - (\d+)( - 1)?\)$/.exec(text);
    if (match) return wrap(0n - BigInt(match[1]) - (match[2] ? 1n : 0n));
    return BigInt(text);
}
function condition() {
    const operator = pick(["==", "!=", "<", ">", "<=", ">="]);
    const left = expression(2), right = expression(2);
    const compare = { "==": (x, y) => x === y, "!=": (x, y) => x !== y, "<": (x, y) => x < y, ">": (x, y) => x > y, "<=": (x, y) => x <= y, ">=": (x, y) => x >= y }[operator];
    return { text: `${left.text} ${operator} ${right.text}`, eval: (env) => compare(left.eval(env), right.eval(env)) };
}
let loops = 0;
function statements(depth, size) {
    const list = [];
    for (let i = 0; i < size; i++) {
        const roll = random();
        if (roll < 0.4 || depth <= 0) {
            const name = pick(names), value = expression(3);
            list.push({ text: `${name} = ${value.text}`, run: (env) => { env[name] = value.eval(env); } });
        } else if (roll < 0.55) {
            const literal = pick(literals);
            list.push({ text: `println("${literal}")`, run: (env) => { env.out += unescape(literal) + "\n"; } });
        } else if (roll < 0.8) {
            const test = condition(), yes = statements(depth - 1, 1 + Math.floor(random() * 2)), no = statements(depth - 1, 1 + Math.floor(random() * 2));
            list.push({
                text: `if (${test.text}) {\n${yes.map((s) => s.text).join("\n")}\n} else {\n${no.map((s) => s.text).join("\n")}\n}`,
                run: (env) => { for (const s of test.eval(env) ? yes : no) s.run(env); },
            });
        } else {
            const counter = `n${loops++}`, bound = 1 + Math.floor(random() * 6), body = statements(depth - 1, 1 + Math.floor(random() * 2));
            list.push({
                text: `var ${counter} = 0\nwhile (${counter} < ${bound}) {\n${body.map((s) => s.text).join("\n")}\n${counter} = ${counter} + 1\n}`,
                run: (env) => { for (let k = 0; k < bound; k++) for (const s of body) s.run(env); },
            });
        }
    }
    return list;
}
function unescape(text) {
    return text.replace(/\\t/g, "\t").replace(/\\n/g, "\n").replace(/\\"/g, "\"");
}
function inside() {
    loops = 0;
    const declarations = names.map((name) => { const text = pick(constants); return { name, value: { text, eval: () => constantValue(text) } }; });
    const body = statements(2, 2 + Math.floor(random() * 4));
    const result = expression(3);
    const text = `import "abla/io"\n\nfun main: int {\n${declarations.map((d) => `var ${d.name} = ${d.value.text}`).join("\n")}\n${body.map((s) => s.text).join("\n")}\n${result.text}\n}\n`;
    const env = { out: "" };
    for (const d of declarations) env[d.name] = d.value.eval(env);
    for (const s of body) s.run(env);
    const value = result.eval(env);
    return { text, model: { stdout: env.out, status: Number(BigInt.asUintN(8, value)), value } };
}
// Just outside the subset: one operation the emitter refuses (or accepts and must get right) in an otherwise ordinary program.
const outside = [
    "a / 3", "a % 5", "a & 255", "a | 1", "a ^ b", "a << 2", "a >> 1", "(0 - a)", "(a < 3) == (b < 4)", "a * b / 7",
];
function outsideProgram() {
    const pattern = pick([
        (x) => `fun main: int {\n    var a = 41\n    var b = 5\n    a = ${x}\n    a\n}\n`,
        (x) => `import "abla/io"\n\nfun main: int {\n    val a = 6\n    val b = 4\n    println("${x.replace(/"/g, "'")}")\n    ${x}\n}\n`,
        (x) => `fun twice(x: int): int = x * 2\n\nfun main: int {\n    var a = twice(21)\n    var b = 1\n    ${x}\n}\n`,
        (x) => `fun main: int {\n    var a = 9\n    var b = 2\n    if (a > b && b > 0) { a = ${x} }\n    a\n}\n`,
        (x) => `import "abla/io"\n\nfun main: int {\n    val s = "text"\n    println(s)\n    val a = 3\n    val b = 8\n    ${x}\n}\n`,
        (x) => `fun main: int {\n    val values = [1, 2, 3]\n    var a = values[1]\n    var b = 4\n    ${x}\n}\n`,
        (x) => `var counter = 0\n\nfun main: int {\n    counter = 5\n    var a = counter\n    var b = 2\n    ${x}\n}\n`,
    ]);
    return { text: pattern(pick(outside)), model: null };
}

function cli(text, name) {
    if (!cliCompiler) return null;
    const source = join(scratch, name + ".ab"), module = join(scratch, name + ".wasm");
    writeFileSync(source, text);
    const built = spawnSync(cliCompiler, ["build", source, "--target", "wasm32-wasi", "--fast", "--no-cache", "-o", module], { encoding: "utf8", timeout: 120000 });
    if (built.status !== 0) return { error: String(built.stderr).split("\n").find((l) => l.startsWith("error")) ?? "build failed" };
    const run = spawnSync("wasmtime", ["run", module], { encoding: "utf8", timeout: 60000 });
    return { stdout: run.stdout, status: run.status };
}

let failures = 0, accepted = 0, refused = 0, parity = 0, validated = 0;
const fail = (name, detail, text) => {
    failures++;
    console.log(`FAIL ${name}: ${detail}`);
    writeFileSync(join(scratch, name + ".failing.ab"), text);
};
let cliUsed = 0;
for (let index = 0; index < count; index++) {
    const insideSubset = index % 4 !== 3;
    const program = insideSubset ? inside() : outsideProgram();
    const name = `${insideSubset ? "in" : "out"}${index}`;
    const compiled = await compileGuest(bounded, base, new Map([["main.ab", program.text]]));
    let guest = null;
    if (compiled.ok) {
        accepted++;
        if (!WebAssembly.validate(compiled.wasm)) { fail(name, "the module does not validate", program.text); continue; }
        validated++;
        try { guest = await runGuest(compiled.wasm, compiled.stdoutBudget); } catch (error) { fail(name, `the guest threw ${error.message}`, program.text); continue; }
    } else {
        refused++;
        if (compiled.wasm !== null) fail(name, "bytes with a failed compile", program.text);
        if (insideSubset) { fail(name, `a program inside the subset was refused: ${compiled.stderr.trim().split("\n")[0]}`, program.text); continue; }
        if (!/E_PLAYGROUND_WASM_UNSUPPORTED|error\[/.test(compiled.stderr)) fail(name, `refused without a diagnostic: ${compiled.stderr.slice(0, 100)}`, program.text);
    }
    if (insideSubset && guest) {
        if (guest.stdout !== program.model.stdout || guest.status !== program.model.status) {
            fail(name, `model says ${JSON.stringify(program.model.stdout.slice(0, 40))}/${program.model.status}, guest ${JSON.stringify(guest.stdout.slice(0, 40))}/${guest.status}`, program.text);
        }
    }
    const wantsCli = cliCompiler && ((insideSubset && cliUsed < cliCount) || !insideSubset);
    if (wantsCli) {
        const reference = cli(program.text, name);
        if (insideSubset) cliUsed++;
        if (reference && !reference.error && guest) {
            parity++;
            // wasmtime reports a proc_exit code above 126 as 1 (a native build exits with the code's low eight bits, which is the guest's status).
            const sameStatus = guest.status === reference.status || (guest.status > 126 && reference.status === 1);
            if (guest.stdout !== reference.stdout || !sameStatus) {
                fail(name, `CLI ${JSON.stringify(reference.stdout.slice(0, 40))}/${reference.status}, guest ${JSON.stringify(guest.stdout.slice(0, 40))}/${guest.status}`, program.text);
            }
        } else if (reference?.error && guest) fail(name, `the CLI refused (${reference.error}) a program the guest ran`, program.text);
    }
}
console.log(`guest fuzz: ${count} programs (${accepted} accepted and validated ${validated}, ${refused} refused), ${parity} compared with the CLI, ${failures} failures; failing programs in ${scratch}`);
if (failures === 0) rmSync(scratch, { recursive: true, force: true });
process.exit(failures === 0 ? 0 : 1);
