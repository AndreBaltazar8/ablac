// MIN / -1 wraps; a zero divisor traps through the panic path ("unreachable"),
// not the division instruction's own trap ("divide by zero").
import { readFileSync } from "node:fs";

const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
const e = instance.exports;
const min64 = -(2n ** 63n);
const check = (label, actual, expected) => {
    if (actual !== expected) throw new Error(`${label} = ${actual}, expected ${expected}`);
};
check("divide(MIN, -1)", e.divide(min64, -1n), min64);
check("remainder(MIN, -1)", e.remainder(min64, -1n), 0n);
check("divide(-7, 2)", e.divide(-7n, 2n), -3n);
check("remainder(-7, 2)", e.remainder(-7n, 2n), -1n);
check("divide32(MIN, -1)", e.divide32(-(2 ** 31), -1), -(2 ** 31));
check("remainder32(MIN, -1)", e.remainder32(-(2 ** 31), -1), 0);
check("divideUnsigned(0xffffffff, 3)", e.divideUnsigned(-1, 3) >>> 0, 0x55555555);
for (const [label, call] of [
    ["divide(7, 0)", () => e.divide(7n, 0n)],
    ["remainder32(7, 0)", () => e.remainder32(7, 0)],
    ["divideUnsigned(7, 0)", () => e.divideUnsigned(7, 0)],
]) {
    let message = "";
    try { call(); } catch (error) { message = String(error.message); }
    if (!/unreachable/.test(message)) {
        throw new Error(`${label}: expected the panic trap, got "${message}"`);
    }
}
console.log("wasm division: MIN / -1 wraps, a zero divisor reaches the panic");
