import { readFileSync } from "node:fs";
const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {
    abla_host: new Proxy({}, { get: () => () => 0 })
});
const result = instance.exports.checks();
if (result !== 0n) throw new Error(`generic named defaults failed on Wasm: ${result}`);
