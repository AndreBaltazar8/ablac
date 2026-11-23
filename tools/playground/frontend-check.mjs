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
process.exit(failed ? 1 : 0);
