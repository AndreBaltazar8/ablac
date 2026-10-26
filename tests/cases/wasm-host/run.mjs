// The browser host ABI (stdlib/abla/runtime/platform/wasm.ab) as a page would
// provide it, and the checks: the module imports abla_host.* only, its output
// reaches the host by descriptor, the clocks read the host's, random bytes come
// from the host, other calls fail with ENOSYS, and exit ends the call with its
// code.
import { readFileSync } from "node:fs";
import { randomFillSync } from "node:crypto";

const fail = (message) => {
    console.error(`wasm host: ${message}`);
    process.exit(1);
};
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const host = new Set(["write", "exit", "clock_ns", "random"]);
for (const entry of WebAssembly.Module.imports(module)) {
    if (entry.module !== "abla_host" || !host.has(entry.name)) {
        fail(`unexpected import ${entry.module}.${entry.name}`);
    }
}

class Exit extends Error {
    constructor(code) {
        super(`exit ${code}`);
        this.code = code;
    }
}
let memory;
const written = { 1: "", 2: "" };
const decoder = new TextDecoder();
const abla_host = {
    write: (fd, data, length) => {
        if (!(fd in written)) return -9; // EBADF
        written[fd] += decoder.decode(new Uint8Array(memory.buffer, data, length));
        return length;
    },
    exit: (code) => {
        throw new Exit(code);
    },
    clock_ns: (clock) => clock === 0
        ? BigInt(Date.now()) * 1000000n
        : BigInt(Math.round(performance.now() * 1e6)),
    random: (data, length) => {
        randomFillSync(new Uint8Array(memory.buffer, data, length));
        return length;
    }
};
const { exports } = new WebAssembly.Instance(module, { abla_host });
memory = exports.memory;

exports.greet();
if (written[1] !== "hello from the module\n") fail(`stdout ${JSON.stringify(written[1])}`);
if (written[2] !== "and its standard error\n") fail(`stderr ${JSON.stringify(written[2])}`);
const wall = exports.wall();
const now = BigInt(Date.now()) * 1000000n;
if (wall <= 0n || wall > now || now - wall > 60000000000n) fail(`wall clock ${wall} (now ${now})`);
const first = exports.monotonic();
const second = exports.monotonic();
if (first <= 0n || second < first) fail(`monotonic clock ${first}, ${second}`);
const draws = new Set();
for (let i = 0; i < 8; i++) draws.add(exports.random());
if (draws.size < 7) fail(`random draws ${[...draws]}`);
if (exports.unsupported() !== -38n) fail(`getpid gave ${exports.unsupported()}, not -ENOSYS`);
try {
    exports.leave(7n);
    fail("exit returned");
} catch (error) {
    if (!(error instanceof Exit) || error.code !== 7) throw error;
}
console.log(`wasm host: ${WebAssembly.Module.imports(module).map((entry) => entry.name).join(", ")}`);
