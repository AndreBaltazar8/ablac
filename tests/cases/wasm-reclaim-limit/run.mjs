// A limit below the default reclaim thresholds (4 MiB parked, then every 1 MiB).
// The runtime lowers both to limit/8 and limit/16 (runtimeMemorySetLimit), so
// parked memory is merged at this size of heap too: with the defaults no reclaim
// ever runs here. The program finishes with the right results, its live bytes
// within the limit. The limit bounds live bytes, not linear memory, which also
// holds what is parked; that isn't asserted beyond a generous sanity bound.
import { readFileSync } from "node:fs";

const module = readFileSync(process.argv[2]);
const sizes = [48n, 80n, 112n, 176n, 240n, 368n, 496n, 752n, 1008n, 1520n, 2032n, 3056n, 4080n, 6128n, 8176n];

for (const limit of [1048576n, 2097152n]) {
    const { instance } = await WebAssembly.instantiate(module, {});
    const exports = instance.exports;
    const absolute = exports.set_limit(limit);
    const baseline = exports.memory.buffer.byteLength;
    let peakLive = 0n;
    for (let round = 0; round < 3; round++) {
        for (const size of sizes) {
            const bytes = limit * 2n;
            // Each string is the slice plus one byte, made until `bytes` are counted.
            const expected = (size + 1n) * ((bytes + size - 1n) / size);
            const result = exports.phase(size, bytes);
            if (result !== expected) throw new Error(`size ${size}: ${result}, expected ${expected}`);
            const live = exports.live();
            if (live > peakLive) peakLive = live;
            if (live > absolute) throw new Error(`size ${size}: ${live} live bytes over the limit ${absolute}`);
        }
    }
    const grown = BigInt(exports.memory.buffer.byteLength - baseline);
    const reclaims = exports.stat(7n);
    console.log(JSON.stringify({
        limit: Number(limit), peakLive: Number(peakLive), memoryGrown: Number(grown),
        collections: Number(exports.stat(5n)), reclaims: Number(reclaims)
    }));
    if (exports.stat(5n) < 2n) throw new Error(`limit ${limit}: the garbage was never collected`);
    if (reclaims < 1n) throw new Error(`limit ${limit}: no reclaim ran, so the thresholds did not follow the limit`);
    if (grown > limit * 5n) throw new Error(`limit ${limit}: memory grew ${grown} bytes`);
}
