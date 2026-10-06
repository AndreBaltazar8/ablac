// The export answers with the implementation's value, and the extern call
// inside the module reaches the same function with the string's address.
import { readFileSync } from "node:fs";

const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
const exports = instance.exports;
if (exports.atof(5) !== 15) throw new Error(`atof(5) = ${exports.atof(5)}, expected 15`);
const probed = exports.probe();
if (!Number.isInteger(probed) || probed <= 10) {
    throw new Error(`probe() = ${probed}, expected 10 + an address`);
}
console.log("wasm export sharing an extern's symbol: atof(5) = 15, probe() reaches it");
