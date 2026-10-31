// What an export stored in a constant-initialized global survives collections
// made with no frame of that export left to hold it.
import { readFileSync } from "node:fs";

const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
const exports = instance.exports;
let collected = 0n;
for (let round = 0n; round < 40n; round++) {
    const value = 42n + round;
    exports.store(value);
    collected += exports.collect();
    exports.churn(2000n);
    collected += exports.collect();
    exports.churn(2000n);
    const read = exports.read(value);
    if (read !== value) throw new Error(`round ${round}: read ${read}, stored ${value}`);
}
// A collector that frees nothing would pass the rest of this.
if (collected < 1000000n) throw new Error(`only ${collected} bytes were collected`);
console.log(`constant-initialized globals stayed rooted through ${collected} collected bytes`);
