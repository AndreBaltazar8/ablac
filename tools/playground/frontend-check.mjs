// Checks the front end built for wasm32 (src/browser_main.ab), under Node with the page's host:
//   node frontend-check.mjs <browser-frontend.wasm> <repository root> [CLI WASI fixtures directory]
// It lowers a hello and a program with a compile-time site, reports a wrong program's error, and runs programs with the compiler's
// evaluator (output, exit status, a runtime error, standard input).
import { spawnSync } from "node:child_process";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";
import { boundedCompiler, compile, compileGuest, createBase, run } from "./host.mjs";
import { runGuest } from "./guest.mjs";
import { runGuestWithDeadline } from "./guest-host.mjs";
import { nodeGuestWorker } from "./node-guest-worker.mjs";

const [wasmPath, root, wasiDirectory] = process.argv.slice(2);
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

let failed = 0;
const check = (name, ok, detail = "") => {
    if (!ok) failed++;
    console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail ? ": " + detail : ""}`);
};

const hello = 'import "abla/io"\n\nfun main: int {\n    println("hello")\n    0\n}\n';
const staged = 'import "abla/io"\n\nfun inc(n: int): int = n + 1\n\nval v = #inc(1)\n\nfun main: int {\n    println("$v")\n    0\n}\n';
for (const [name, source] of [["hello", hello], ["compile-time site", staged]]) {
    const result = await compile(module, base, new Map([["main.ab", source]]));
    const lowered = /lowered: (\d+) functions/.exec(result.stderr);
    check(`lower ${name}`, result.status === 0 && lowered !== null, lowered ? `${lowered[1]} functions` : result.stderr.slice(0, 200));
}
const wrong = await compile(module, base, new Map([["main.ab", 'fun main: int = "wrong"\n']]));
check("a wrong return type is an error", wrong.status === 1 && /E_SEMANTIC|error\[/.test(wrong.stderr), wrong.stderr.split("\n").find((line) => line.startsWith("error")) ?? "");

// The parser stops at 128 levels of nesting in the browser (a nested block counts two): the module has a 4 MiB wasm stack, the release build's depth then ends at the engine's own stack near 450 and the development build traps near 180 nested parentheses (a 1 MiB stack trapped at about 160 blocks). A program that nests 50 blocks compiles, and one that nests 100 blocks or 300 parentheses is one E_PARSE_NESTING error, not a trap or a RangeError.
const nestedBlocks = (n) => { let s = "fun nested(x: int): int {\n"; for (let l = 0; l < n; l++) s += `val a${l} = x + ${l}\nif (a${l} > ${l}) {\n`; s += "x\n"; for (let l = n - 1; l >= 0; l--) s += `} else a${l}\n`; return s + "}\nfun main: int = nested(1)\n"; };
const shallow = await compile(module, base, new Map([["main.ab", nestedBlocks(50)]]));
check("50 nested blocks compile", shallow.status === 0, shallow.stderr.slice(0, 150));
for (const [name, source] of [["100 nested blocks", nestedBlocks(100)], ["300 nested parentheses", `fun main: int = ${"(".repeat(300)}1${")".repeat(300)}\n`]]) {
    let outcome;
    try {
        const deep = await compile(module, base, new Map([["main.ab", source]]));
        const errors = deep.stderr.split("\n").filter((line) => line.startsWith("error[")).length;
        outcome = deep.status === 1 && errors === 1 && /E_PARSE_NESTING/.test(deep.stderr) ? "" : `status ${deep.status}, ${errors} errors: ${deep.stderr.slice(0, 120)}`;
    } catch (error) { outcome = `the module trapped: ${error.message}`; }
    check(`${name} are one E_PARSE_NESTING error`, outcome === "", outcome);
}

// A program whose project is the file system root: compile-time code reads its own file there (a prefix test written "$root/" would be "//").
for (const [root, cwd] of [["/work", "/work"], ["/", "/"], ["/work", "/"]]) {
    const reader = 'import "abla/io"\nimport "abla/fs"\nimport "abla/compiler"\n\n#compilerGrant("filesystem.read")\n\nval text = #path("data.txt").readText()\n\nfun main: int {\n    println(text)\n    0\n}\n';
    const project = new Map([["main.ab", reader], ["data.txt", "from the project\n"], ["abla.toml", 'compileCapabilities = ["filesystem.read"]\n']]);
    const result = await compile(module, base, project, { root, cwd });
    check(`a compile-time read, project at ${root}, working directory ${cwd}`, result.status === 0 && result.stdout === "" && /errors=0 /.test(result.stderr), result.stderr.split("\n").find((line) => line.startsWith("error")) ?? "");
}

const fib = 'import "abla/io"\n\nfun fib(n: int): int = if (n < 2) n else fib(n - 1) + fib(n - 2)\n\nfun main: int {\n    println("fib = ${fib(20)}")\n    3\n}\n';
const ran = await run(module, base, new Map([["main.ab", fib]]));
check("run: output and exit status", ran.ok && ran.stdout === "fib = 6765\n" && ran.status === 3, JSON.stringify({ status: ran.status, stdout: ran.stdout }));
const bad = await run(module, base, new Map([["main.ab", 'import "abla/io"\n\nfun main: int {\n    val items: array<int> = [1, 2]\n    println("${items[5]}")\n    0\n}\n']]));
check("run: a runtime error names itself", !bad.ok && /out of bounds/.test(bad.diagnostics), bad.diagnostics.split("\n")[0]);
const echo = 'import "abla/io"\n\nfun main {\n    val line = readLine()\n    println("got ${line}")\n}\n';
const input = await run(module, base, new Map([["main.ab", echo]]), { stdin: "ping\n" });
check("run: standard input", input.ok && input.stdout === "got ping\n", JSON.stringify({ stdout: input.stdout, diagnostics: input.diagnostics.slice(0, 160) }));
// A loop of 800,000 small objects: the module collects them (a Wasm module collects only when asked to, src/browser_main.ab), so it stays far
// below the 2.4 GB it took when nothing was collected.
const churn = 'import "abla/io"\n\nclass Node(val value: int, val next: Node?)\n\nfun sumList(node: Node?): int = if (node == null) 0 else node.value + sumList(node.next)\n\nfun churn(round: int): int {\n    var list: Node? = null\n    for (index in 0 until 40) list = Node(index + round, list)\n    sumList(list)\n}\n\nfun main: int {\n    var total = 0\n    for (round in 0 until 20000) total = total + churn(round)\n    println("total $total")\n    0\n}\n';
const churned = await run(module, base, new Map([["main.ab", churn]]));
check("run: garbage is collected", churned.ok && churned.stdout === "total 8015200000\n" && churned.memoryBytes < 1024 * 1024 * 1024, JSON.stringify({ status: churned.status, megabytes: Math.round(churned.memoryBytes / 1048576), diagnostics: churned.diagnostics.slice(0, 120) }));

// Limits of a run (the page runs a visitor's program in this module): output stops at its limit, a program that allocates without end stops
// at the memory limit of a bounded module, and both come back as ordinary failed runs, not as exceptions.
const bounded = await boundedCompiler(readFileSync(wasmPath));
const flood = 'import "abla/io"\n\nfun main: int {\n    var i = 0\n    while (i < 1000000) {\n        println("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")\n        i = i + 1\n    }\n    0\n}\n';
const flooded = await run(bounded, base, new Map([["main.ab", flood]]));
check("run: output stops at the limit", !flooded.ok && flooded.stdout.length <= 1048576 && flooded.stdout.length > 1000000 && /output passed 1048576 bytes/.test(flooded.diagnostics),
    JSON.stringify({ ok: flooded.ok, stdout: flooded.stdout.length, diagnostics: flooded.diagnostics.slice(-120) }));
const hungry = 'import "abla/io"\n\nfun main: int {\n    var all: array<string> = []\n    var i = 0\n    while (i < 100000000) {\n        all.append("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx$i")\n        i = i + 1\n    }\n    println("${all.size}")\n    0\n}\n';
let grown;
try { grown = await run(bounded, base, new Map([["main.ab", hungry]])); } catch (error) { grown = { ok: true, diagnostics: `threw ${error.message}`, memoryBytes: 0 }; }
check("run: allocation stops at the memory limit", !grown.ok && grown.memoryBytes <= 1073741824 && /memory|E_EVAL_STEP_LIMIT|limit/.test(grown.diagnostics),
    JSON.stringify({ ok: grown.ok, megabytes: Math.round(grown.memoryBytes / 1048576), diagnostics: grown.diagnostics.slice(-160) }));
const small = await run(bounded, base, new Map([["main.ab", fib]]));
check("run: a bounded module still runs a program", small.ok && small.stdout === "fib = 6765\n" && small.status === 3, JSON.stringify({ ok: small.ok, status: small.status }));

const cases = join(root, "tests/cases/wasm-browser-frontend");
for (const [name, status, stdout] of [
    ["compiled-hello", 0, "hello from Wasm\n"],
    ["compiled-loop", 7, ""],
]) {
    const source = readFileSync(join(cases, name + ".ab"));
    const compiled = await compileGuest(bounded, base, new Map([["main.ab", source]]));
    check(`emit ${name}`, compiled.ok && compiled.wasm instanceof ArrayBuffer && compiled.stdout === "", compiled.stderr.trim());
    if (!compiled.ok) continue;
    const guest = await runGuest(compiled.wasm, compiled.stdoutBudget);
    check(`run ${name}`, guest.stdout === stdout && guest.status === status && guest.memoryBytes === 65536);
    const cliOutput = wasiDirectory ? join(wasiDirectory, name + ".wasm") : "";
    if (cliOutput && existsSync(cliOutput)) {
        const cli = spawnSync("wasmtime", ["run", cliOutput], { encoding: "utf8", timeout: 30000 });
        check(`CLI WASI parity ${name}`, !cli.error && cli.status === guest.status && cli.stdout === guest.stdout,
            cli.error?.message ?? String(cli.stderr).trim());
    } else console.log(`skip CLI WASI parity ${name} (wasmtime or its comparison module is missing)`);
    if (name === "compiled-hello") {
        const capped = await runGuest(compiled.wasm, 3);
        check("guest output obeys the remaining byte budget", capped.status === 1 && capped.outputTruncated && capped.stdout === "hel");
        const foreignImport = Buffer.from(compiled.wasm.slice(0));
        const namespace = foreignImport.indexOf("abla_playground");
        if (namespace >= 0) foreignImport[namespace] = 120;
        let rejected = false;
        try {
            await runGuest(foreignImport);
        } catch (error) {
            rejected = /Unexpected playground guest imports/.test(error.message);
        }
        check("guest denies a module requesting another import", namespace >= 0 && rejected);
        const oversized = Buffer.from(compiled.wasm.slice(0));
        const memory = oversized.indexOf(Buffer.from([5, 4, 1, 1, 1, 16]));
        let cappedMemory = false;
        if (memory >= 0) {
            oversized[memory + 4] = 17;
            oversized[memory + 5] = 17;
            try {
                await runGuest(oversized);
            } catch (error) {
                cappedMemory = error.message === "memory-limit";
            }
        }
        check("guest denies a valid module with more than 16 initial pages",
            memory >= 0 && WebAssembly.validate(oversized) && cappedMemory);
    }
}
const unsupported = await compileGuest(bounded, base, new Map([["main.ab",
    'fun main: int { var value = 7; value / 2 }\n',
]]));
check("compiled mode rejects operations outside its subset",
    !unsupported.ok && unsupported.wasm === null && /unsupported lowered operation/.test(unsupported.stderr),
    unsupported.stderr.trim());
const initialized = await compileGuest(bounded, base, new Map([["main.ab",
    'val value = 7\nfun main: int = value\n',
]]));
check("compiled mode rejects project runtime initialization",
    !initialized.ok && initialized.wasm === null && /without runtime global initializers/.test(initialized.stderr),
    initialized.stderr.trim());

// Compile-phase output counts against the guest's budget; the limits of the subset refuse instead of emitting; a loop that never ends is
// stopped by the page's deadline (#1139 area 11).
const noisy = await compileGuest(bounded, base, new Map([["main.ab",
    'import "abla/io"\n\nfun noise(): int {\n    println("compile-time noise")\n    1\n}\n\nfun main: int {\n    val k = #noise()\n    println("hi")\n    k\n}\n',
]]));
check("compile-phase stdout is subtracted from the guest's output budget",
    noisy.ok && noisy.stdout === "compile-time noise\n" && noisy.stdoutBudget === 1048576 - 19, JSON.stringify({ ok: noisy.ok, stdout: noisy.stdout, budget: noisy.stdoutBudget, stderr: noisy.stderr.slice(0, 100) }));
const longLiteral = await compileGuest(bounded, base, new Map([["main.ab", `import "abla/io"\n\nfun main: int {\n    println("${"x".repeat(70000)}")\n    0\n}\n`]]));
check("a literal that does not fit the 64 KiB memory is refused", !longLiteral.ok && longLiteral.wasm === null && /unsupported lowered operation/.test(longLiteral.stderr), longLiteral.stderr.slice(0, 120));
let manyLines = 'import "abla/io"\n\nfun main: int {\n';
for (let line = 0; line < 600; line++) manyLines += `    println("${"y".repeat(120)}")\n`;
manyLines += "    0\n}\n";
const crowded = await compileGuest(bounded, base, new Map([["main.ab", manyLines]]));
check("literals that together pass 64 KiB are refused", !crowded.ok && crowded.wasm === null && /unsupported lowered operation/.test(crowded.stderr), crowded.stderr.slice(0, 120));
let straight = "fun main: int {\n    var a = 1\n";
for (let line = 0; line < 3000; line++) straight += "    a = a + 1\n";
straight += "    a\n}\n";
const tooLong = await compileGuest(bounded, base, new Map([["main.ab", straight]]));
check("a main with more than 4096 lowered instructions is refused", !tooLong.ok && tooLong.wasm === null && /the prototype accepts/.test(tooLong.stderr), tooLong.stderr.slice(0, 120));
const spin = await compileGuest(bounded, base, new Map([["main.ab", "fun main: int {\n    var i = 0\n    while (i != 12345678901) {\n        i = i + 2\n    }\n    0\n}\n"]]));
check("an endless loop compiles to a guest", spin.ok && WebAssembly.validate(spin.wasm), spin.stderr.slice(0, 120));
if (spin.ok) {
    const stopped = await Promise.race([runGuestWithDeadline(spin.wasm, spin.stdoutBudget, { timeoutMilliseconds: 800, spawn: nodeGuestWorker }), new Promise((resolve) => setTimeout(() => resolve({ hung: true }), 6000))]);
    check("the page stops an endless loop at its deadline", stopped.timedOut === true, JSON.stringify(stopped));
}
const reader = 'import "abla/fs"\n\nfun size(): int = path("main.ab").readText().size\n\nfun main: int {\n    val n = #size()\n    n\n}\n';
const hostile = await compileGuest(bounded, base, new Map([["main.ab", reader], ["abla.toml", 'compileCapabilities = ["filesystem.read", "filesystem.write", "trusted.native"]\n']]));
check("a project's own abla.toml cannot grant the compile-time site a capability", !hostile.ok && hostile.wasm === null && /compile\.effect-denied|capability/.test(hostile.stderr), hostile.stderr.slice(0, 160));

process.exit(failed ? 1 : 0);
