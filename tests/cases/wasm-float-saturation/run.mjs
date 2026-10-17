// Each conversion of an out-of-range or NaN input gives its saturated value
// (a trapping truncation would throw here).
import { readFileSync } from "node:fs";

const { exports } = (await WebAssembly.instantiate(readFileSync(process.argv[2]), {})).instance;
const checks = [
    ["to_i32", 1e20, 2147483647], ["to_i32", -1e20, -2147483648],
    ["to_i32", NaN, 0], ["to_i32", -3.9, -3],
    ["to_u32", 1e20, 4294967295], ["to_u32", -5.5, 0], ["to_u32", NaN, 0],
    ["to_u32", 3.9, 3],
    ["to_i64", 1e300, 9223372036854775807n], ["to_i64", -1e300, -9223372036854775808n],
    ["to_i64", NaN, 0n],
];
for (const [name, input, expected] of checks) {
    let actual = exports[name](input);
    if (name === "to_u32") actual = actual >>> 0;
    if (actual !== expected) {
        throw new Error(`${name}(${input}) = ${actual}, expected ${expected}`);
    }
}
console.log(`wasm float saturation: ${checks.length} conversions`);
