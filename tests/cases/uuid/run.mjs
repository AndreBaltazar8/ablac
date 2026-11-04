import { readFileSync } from "node:fs";
const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {
    abla_host: new Proxy({}, { get: (_, name) => name === "clock_ns" ? () => 0n : () => 0 })
});
const result = instance.exports.checks();
if (result !== 0n) throw new Error(`UUID Wasm check failed: ${result}`);

const parseModule = new WebAssembly.Module(readFileSync(process.argv[3]));
const imports = WebAssembly.Module.imports(parseModule);
if (imports.length !== 0) throw new Error(`parse-only UUID module imports ${JSON.stringify(imports)}`);
if (new WebAssembly.Instance(parseModule, {}).exports.checks() !== 0n) throw new Error("hostless UUID parser failed");
