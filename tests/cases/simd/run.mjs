import { readFileSync } from "node:fs";

const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {
    abla_host: new Proxy({}, { get: () => () => 0 })
});
const failed = instance.exports.checks();
if (failed !== 0n) throw new Error(`check ${failed} failed on Wasm`);
const rounded = instance.exports.simd_round_probe(2.5, 3.5, -1.5, 0.5);
if (rounded !== 4) throw new Error(`runtime lane rounding gave ${rounded}, expected 4`);
