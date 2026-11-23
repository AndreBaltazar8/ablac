// The front-end module is valid, asks the page for nothing but the browser host's imports (abla_host write, exit, clock_ns, random,
// and the two C functions its process and string code names: fork, which the page answers -1, and strlen), and exports `main`.
import { readFileSync, statSync } from "node:fs";

const path = process.argv[2];
const limitMegabytes = Number(process.argv[3]);
const fail = (message) => {
    console.error(`browser front end: ${message}`);
    process.exit(1);
};
const bytes = readFileSync(path);
if (!WebAssembly.validate(bytes)) fail("not a valid module");
const module = new WebAssembly.Module(bytes);
const allowed = new Set(["abla_host.syscall", "env.fork", "env.strlen"]);
for (const entry of WebAssembly.Module.imports(module)) {
    if (!allowed.has(`${entry.module}.${entry.name}`)) fail(`unexpected import ${entry.module}.${entry.name}`);
}
const exported = WebAssembly.Module.exports(module).map((entry) => entry.name);
if (!exported.includes("main") || !exported.includes("memory")) fail(`exports ${exported.slice(0, 8)}`);
const size = statSync(path).size;
if (size > limitMegabytes * 1048576) fail(`${size} bytes is over ${limitMegabytes} MB`);
console.log(`browser front end: valid module, ${(size / 1048576).toFixed(1)} MB, imports ${WebAssembly.Module.imports(module).map((entry) => entry.name).join(", ")}`);
