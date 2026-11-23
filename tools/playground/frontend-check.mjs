// Compiles programs through lowering with the front end built for wasm32 (src/browser_main.ab), under Node with the page's host:
//   node frontend-check.mjs <browser-frontend.wasm> <repository root> [program.ab ...]
// Each program is checked for status 0 and a `lowered: N functions` line; with none named, a hello and the suite's small programs.
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { compile, createBase } from "./host.mjs";

const [wasmPath, root, ...named] = process.argv.slice(2);
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

const hello = 'import "abla/io"\n\nfun main: int {\n    println("hello")\n    0\n}\n';
const programs = named.length
    ? named.map((path) => [path, readFileSync(path, "utf8")])
    : [["hello.ab", hello]];
let failed = 0;
for (const [name, source] of programs) {
    const started = performance.now();
    const result = await compile(module, base, new Map([["main.ab", source]]));
    const lowered = /lowered: (\d+) functions, (\d+) instructions/.exec(result.stderr);
    const ok = result.status === 0 && lowered !== null;
    if (!ok) failed++;
    console.log(`${ok ? "ok  " : "FAIL"} ${name}: ${lowered ? `${lowered[1]} functions, ${lowered[2]} instructions` : result.stderr.slice(0, 300)} (${(performance.now() - started).toFixed(0)} ms)`);
}
process.exit(failed ? 1 : 0);
