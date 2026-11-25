import { outputLimitBytes } from "./host.mjs";
import { withBoundedMemory } from "./wasm-memory.mjs";

const guestMemoryPages = 16;
const guestModuleLimit = 1048576;
// The prototype needs one memory, one function import and no tables or start
// function. The section allowlist also rejects extensions to that module shape.
const guestSections = new Set([1, 2, 3, 5, 7, 10, 11]);

export async function runGuest(bytes, stdoutBudget = outputLimitBytes) {
    if (!(bytes instanceof Uint8Array || bytes instanceof ArrayBuffer) || bytes.byteLength > guestModuleLimit) {
        throw new Error("Invalid playground guest module size");
    }
    if (!Number.isInteger(stdoutBudget) || stdoutBudget < 0 || stdoutBudget > outputLimitBytes) {
        throw new Error("Invalid playground guest output budget");
    }
    const bounded = withBoundedMemory(bytes, guestMemoryPages, guestSections);
    const module = await WebAssembly.compile(bounded.binary);
    const imports = WebAssembly.Module.imports(module);
    const exports = WebAssembly.Module.exports(module);
    if (imports.length !== 2 ||
        !imports.some(entry => entry.module === "env" && entry.name === "memory" && entry.kind === "memory") ||
        !imports.some(entry => entry.module === "abla_playground" && entry.name === "write" && entry.kind === "function") ||
        exports.length !== 1 || exports[0].name !== "main" || exports[0].kind !== "function") {
        throw new Error("Unexpected playground guest imports or exports");
    }

    const memory = new WebAssembly.Memory({ initial: bounded.initial, maximum: bounded.maximum });
    const output = new Uint8Array(stdoutBudget);
    const limit = new Error("Playground guest output limit");
    let length = 0;
    const write = (pointer, count) => {
        const start = pointer >>> 0;
        const size = count >>> 0;
        const heap = memory.buffer;
        if (start > heap.byteLength || size > heap.byteLength - start) {
            throw new Error("Playground guest write outside linear memory");
        }
        const kept = Math.min(size, output.length - length);
        output.set(new Uint8Array(heap, start, kept), length);
        length += kept;
        if (kept !== size) throw limit;
    };
    const instance = await WebAssembly.instantiate(module, { env: { memory }, abla_playground: { write } });
    let status;
    let outputTruncated = false;
    try {
        status = instance.exports.main();
    } catch (error) {
        if (error !== limit) throw error;
        status = 1;
        outputTruncated = true;
    }
    if (!Number.isInteger(status)) throw new Error("Invalid playground guest status");
    return {
        status,
        stdout: new TextDecoder().decode(output.subarray(0, length)),
        outputTruncated,
        memoryBytes: memory.buffer.byteLength,
    };
}
