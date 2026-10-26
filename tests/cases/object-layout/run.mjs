// Prints run() of the object-layout module: how many checks failed.
import { readFileSync } from "node:fs";

const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
console.log(String(instance.exports.run()));
