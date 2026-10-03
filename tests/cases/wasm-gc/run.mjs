// Differential collector check: two instances of the same module receive the
// same calls; one collects after every round, the other never does. Every
// observable result must match, and the collecting instance's linear memory
// must stay bounded while the other grows.
import { readFileSync } from "node:fs";

const bytes = readFileSync(process.argv[2]);
const rounds = Number(process.argv[3] ?? 300);
const make = async () => (await WebAssembly.instantiate(bytes, {})).instance.exports;
const collecting = await make();
const reference = await make();
let collectedBytes = 0n;
let collectMilliseconds = 0;
let peakBytes = 0;
const started = performance.now();
for (let round = 0; round < rounds; round++) {
    collecting.mutate(round);
    reference.mutate(round);
    if (collecting.churn(2000) !== reference.churn(2000)) {
        throw new Error(`churn diverged in round ${round}`);
    }
    const collectStarted = performance.now();
    collectedBytes += collecting.collect();
    collectMilliseconds += performance.now() - collectStarted;
    if (round % 50 === 0 &&
        collecting.collect_holding() !== reference.collect_holding()) {
        throw new Error(`rooted locals diverged in round ${round}`);
    }
    if (collecting.checksum() !== reference.checksum()) {
        throw new Error(`global state diverged in round ${round}`);
    }
    peakBytes = Math.max(peakBytes, collecting.memory.buffer.byteLength);
}
const summary = {
    rounds,
    liveBytes: Number(collecting.live()),
    referenceLiveBytes: Number(reference.live()),
    peakMemoryMB: +(peakBytes / 1e6).toFixed(1),
    referenceMemoryMB: +(reference.memory.buffer.byteLength / 1e6).toFixed(1),
    collectedMB: +(Number(collectedBytes) / 1e6).toFixed(1),
    averageCollectMs: +(collectMilliseconds / rounds).toFixed(3),
    totalMs: Math.round(performance.now() - started)
};
console.log(JSON.stringify(summary));
if (summary.liveBytes > 1e6) throw new Error("live bytes did not stay flat");
if (peakBytes * 4 > reference.memory.buffer.byteLength) {
    throw new Error("collecting instance memory was not bounded");
}
