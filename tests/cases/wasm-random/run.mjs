// node run.mjs probe.wasm wasi.wasm: the bare module against abla_host hosts (good, failing, no progress, short) and the WASI module against a good and a failing random_get.
import { readFileSync } from "node:fs";
import { randomFillSync } from "node:crypto";
import { WASI } from "node:wasi";
const fail = (m) => { console.error(`wasm-random: ${m}`); process.exit(1); };
const bare = new WebAssembly.Module(readFileSync(process.argv[2]));
function host(mode) {
    let memory;
    const abla_host = {
        write: (fd, data, length) => length, exit: (c) => { throw new Error("exit " + c); }, clock_ns: () => 0n,
        random: (data, length) => {
            if (mode === "good") { randomFillSync(new Uint8Array(memory.buffer, data, length)); return length; }
            if (mode === "error") return -5;
            if (mode === "zero") return 0;
            if (mode === "short") { randomFillSync(new Uint8Array(memory.buffer, data, 1)); return 1; }
        }
    };
    const instance = new WebAssembly.Instance(bare, { abla_host });
    memory = instance.exports.memory;
    return instance.exports;
}
for (const mode of ["good", "short"]) {
    const e = host(mode);
    if (e.draw(32n) !== 32n || e.secure(32n) !== 32n || e.keygen() !== 32n) fail(`${mode} host: no 32 random bytes`);
}
for (const mode of ["error", "zero"]) {
    const e = host(mode);
    if (e.draw(32n) !== 0n || e.secure(32n) >= 0n || e.keygen() !== -1n) fail(`${mode} host: a failing host's call gave bytes or a key`);
}
// A WASI host of its own (node's WASI does not run these modules): random_get fills or fails, environ and args are empty, proc_exit ends the run with its code.
class Exit extends Error { constructor(code) { super("exit"); this.code = code; } }
function wasi(stub) {
    const module = new WebAssembly.Module(readFileSync(process.argv[3]));
    let memory;
    const calls = {
        proc_exit: (code) => { throw new Exit(code); },
        random_get: (data, length) => {
            if (stub) return 29; // EIO
            randomFillSync(new Uint8Array(memory.buffer, data, length));
            return 0;
        }
    };
    const imports = {};
    for (const entry of WebAssembly.Module.imports(module)) imports[entry.name] = calls[entry.name] ?? (() => 0);
    const instance = new WebAssembly.Instance(module, { wasi_snapshot_preview1: imports });
    memory = instance.exports.memory;
    try { instance.exports._start(); } catch (error) { if (error instanceof Exit) return error.code; throw error; }
    return 0;
}
if (wasi(false) !== 0) fail("WASI: random_get did not give 32 random bytes");
if (wasi(true) !== 7) fail("WASI: a failing random_get did not fail the call");
console.log("wasm-random: abla_host.random and WASI random_get are the source with no cryptoSetRandom; a failing host fails the call");
