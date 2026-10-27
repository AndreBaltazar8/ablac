// Calls check() of a module built from module.ab; its imports (what a panic
// reaches) must never be called.
import { readFileSync } from "node:fs";

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const imports = {};
for (const entry of WebAssembly.Module.imports(module)) {
    imports[entry.module] ??= {};
    imports[entry.module][entry.name] = () => {
        throw new Error(`${entry.module}.${entry.name} called`);
    };
}
const { exports } = new WebAssembly.Instance(module, imports);
const result = exports.check();
if (result !== 42n) {
    console.error(`null default leave: ${process.argv[2]} check() = ${result}`);
    process.exit(1);
}
