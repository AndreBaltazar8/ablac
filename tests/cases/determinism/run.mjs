// Prints a WebAssembly module's simulation hash after the given steps.
import { readFileSync } from "node:fs";

const bytes = readFileSync(process.argv[2]);
const steps = Number(process.argv[3] ?? 600);
const { instance } = await WebAssembly.instantiate(bytes, {});
console.log(String(instance.exports.simulate(steps)));
