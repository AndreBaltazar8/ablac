// Prints run(limit) of a generator-wasm module.
import { readFileSync } from "node:fs";

const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
console.log(String(instance.exports.run(Number(process.argv[3]))));
