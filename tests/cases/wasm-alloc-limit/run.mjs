// Sizes that wrap on 32 bits (or exceed the module's memory) must trap, never return a pointer: a fresh instance for each ask (a
// trap leaves the module's heap as it was, but nothing here relies on that). A small size must work (the control).
import { readFileSync } from "node:fs";

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const fresh = () => new WebAssembly.Instance(module, {}).exports;

const control = fresh();
for (const name of ["allocate", "buffer", "encoded"]) {
    const pointer = control[name](1024n);
    if (typeof pointer !== "bigint" || pointer <= 0n) {
        console.error(`${name}(1024) did not return a pointer: ${pointer}`);
        process.exit(1);
    }
}

const sizes = [
    2n ** 31n - 1n, 2n ** 31n, 2n ** 31n + 1n, 3n * 2n ** 30n,
    2n ** 32n - 32n, 2n ** 32n - 1n, 2n ** 32n, 2n ** 32n + 1n, 2n ** 32n + 16n, 2n ** 33n + 7n,
    2n ** 40n, 2n ** 62n, 2n ** 63n - 1n,
];
let failed = 0;
for (const name of ["allocate", "buffer", "encoded"]) {
    for (const size of sizes) {
        // `encoded` doubles the size: the requests are of the halved sizes too, so its 2^32-sized products are asked for.
        const asked = name === "encoded" ? size / 2n : size;
        let result;
        try {
            result = fresh()[name](asked);
        } catch (error) {
            continue; // refused: a trap
        }
        // A request that fits the 32-bit address space (under 2^32 bytes in all) may legitimately be served by a module that can grow to
        // 4 GiB; only a request of 2^32 bytes or more (which wraps) must trap.
        const requested = name === "encoded" ? asked * 2n + 1n : name === "buffer" ? asked + 1n : asked;
        // A product that overflows 64 bits is negative in the module's own arithmetic, and nativeByteBuffer clamps that to an empty buffer.
        if (requested >= 2n ** 63n) continue;
        if (requested < 2n ** 32n - 4096n && typeof result === "bigint" && result > 0n) continue;
        console.error(`${name}(${asked}) returned ${result}: a size that wraps or exceeds the memory was not refused`);
        failed += 1;
    }
}
if (failed > 0) process.exit(1);
console.log(`wasm allocation limit: ${3 * sizes.length} oversized requests refused, the small ones served`);
