// Every shadowing check answers 42 in the WebAssembly build too.
import { readFileSync } from "node:fs";

const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
const result = BigInt(instance.exports.run());
if (result !== 42n) throw new Error(`run() = ${result}, expected 42`);
console.log("wasm local shadowing: run() = 42");
