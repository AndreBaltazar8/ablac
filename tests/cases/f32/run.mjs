import { readFileSync } from "node:fs";

const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {
    abla_host: new Proxy({}, { get: () => () => 0 })
});
const failed = instance.exports.checks();
if (failed !== 0n) throw new Error(`check ${failed} failed on Wasm`);
if (instance.exports.scale(2) !== 3) throw new Error("an f32 export did not scale");
