import { readFileSync } from "node:fs";
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const imports = WebAssembly.Module.imports(module);
if (imports.length !== 0) throw new Error(`unexpected imports: ${JSON.stringify(imports)}`);
const { exports } = new WebAssembly.Instance(module, {});
const result = exports.check();
if (result !== 0n) throw new Error(`float representation check failed: ${result}`);
