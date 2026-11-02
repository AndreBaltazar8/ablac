import { readFileSync } from "node:fs";

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const needed = WebAssembly.Module.imports(module).filter((entry) => entry.module !== "abla_host");
if (needed.length !== 0) throw new Error(`imports ${JSON.stringify(needed)}`);
const instance = new WebAssembly.Instance(module, { abla_host: new Proxy({}, { get: () => () => 0 }) });
const failed = instance.exports.checks();
if (failed !== 0n) throw new Error(`line ${failed} failed on Wasm`);
