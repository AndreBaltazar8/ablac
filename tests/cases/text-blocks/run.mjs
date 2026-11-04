import { readFileSync } from "node:fs";
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const imports = WebAssembly.Module.imports(module);
if (imports.length) throw new Error(`unexpected imports: ${JSON.stringify(imports)}`);
const result = new WebAssembly.Instance(module, {}).exports.checks();
if (result !== 0n) throw new Error(`raw text blocks failed on Wasm: ${result}`);
