// Each extern is imported from the module (and field) its `@wasmImport`
// names; the unannotated one stays in "env". The imports resolve against
// those modules at instantiation.
import { readFileSync } from "node:fs";

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const imports = WebAssembly.Module.imports(module)
    .map(({ module, name, kind }) => `${module}.${name}:${kind}`)
    .sort();
const expected = [
    "env.env_log:function",
    "host.now_millis:function",
    "wasi_snapshot_preview1.fd_write:function",
];
if (JSON.stringify(imports) !== JSON.stringify(expected)) {
    throw new Error(`imports = ${JSON.stringify(imports)}, expected ${JSON.stringify(expected)}`);
}
const logged = [];
const instance = new WebAssembly.Instance(module, {
    env: { env_log: (pointer, length) => logged.push(pointer + length) },
    host: { now_millis: () => 40n },
    wasi_snapshot_preview1: { fd_write: (fd) => fd },
});
const result = instance.exports.probe(1);
if (result !== 41n || logged.length !== 1 || logged[0] !== 2) {
    throw new Error(`probe(1) = ${result}, logged ${JSON.stringify(logged)}`);
}
console.log("wasm imports: @wasmImport sets module and field, unannotated externs stay in env");
