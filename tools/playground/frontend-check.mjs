// Checks the front end built for wasm32 (src/browser_main.ab), under Node with the page's host:
//   node frontend-check.mjs <browser-frontend.wasm> <repository root>
// It lowers a hello and a program with a compile-time site, reports a wrong program's error, and runs programs with the compiler's
// evaluator (output, exit status, a runtime error, standard input).
import { readFileSync, readdirSync } from "node:fs";
import { join, relative } from "node:path";
import { compile, createBase, run } from "./host.mjs";

const [wasmPath, root] = process.argv.slice(2);
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
process.exit(failed ? 1 : 0);
