// Runs a benchmark module's `main` under Node with the abla_host imports and no
// others: prints the instantiate time, the run time in nanoseconds and the
// program's own output on stdout (as JSON, one line).
import { readFileSync } from "node:fs";

const bytes = readFileSync(process.argv[2]);
const module = new WebAssembly.Module(bytes);
for (const entry of WebAssembly.Module.imports(module)) {
    if (entry.module !== "abla_host") throw new Error(`import ${entry.module}.${entry.name}`);
}
let memory;
let output = "";
const decoder = new TextDecoder();
const abla_host = {
    write: (fd, data, length) => {
        if (fd === 1) output += decoder.decode(new Uint8Array(memory.buffer, data >>> 0, length >>> 0));
        return length;
    },
    exit: (code) => {
        throw new Error(`exit ${code}`);
    },
    clock_ns: (clock) => clock === 0
        ? BigInt(Date.now()) * 1000000n
        : BigInt(Math.round(performance.now() * 1e6)),
    random: (data, length) => {
        new Uint8Array(memory.buffer, data >>> 0, length >>> 0).fill(7);
        return length;
    }
};
const started = performance.now();
const { exports } = new WebAssembly.Instance(module, { abla_host });
memory = exports.memory;
const instantiated = performance.now();
const status = exports.main();
const finished = performance.now();
console.log(JSON.stringify({
    instantiateMs: instantiated - started,
    runMs: finished - instantiated,
    status: Number(status),
    output,
    memoryBytes: memory.buffer.byteLength
}));
