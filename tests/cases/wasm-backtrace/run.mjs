// argv: <module.wasm> <plain | backtrace>
// A release module has no name section and its trap's stack shows function indices; with --backtrace it keeps the
// name section, and the stack names the functions.
import { readFileSync } from "node:fs";
const [path, mode] = process.argv.slice(2);
const module = new WebAssembly.Module(readFileSync(path));
const names = WebAssembly.Module.customSections(module, "name").length;
const imports = {};
for (const i of WebAssembly.Module.imports(module)) {
    imports[i.module] ??= {};
    imports[i.module][i.name] = () => 0;
}
const instance = new WebAssembly.Instance(module, imports);
let stack = "";
try { instance.exports.crash(7n); } catch (error) { stack = String(error.stack); }
const fail = (why) => { throw new Error(`${mode}: ${why}\n${stack}`); };
if (!stack.startsWith("RuntimeError")) fail("no trap");
if (mode === "plain") {
    if (names !== 0) fail("a release module kept its name section");
    if (!/wasm-function\[\d+\]/.test(stack)) fail("the stack has no function index");
} else {
    if (names !== 1) fail("no name section");
    if (!/\bcrash\.crash \(/.test(stack)) fail("the stack names no crash.crash");
    if (!/__ablaRuntimePanic \(/.test(stack)) fail("the stack names no panic");
}
