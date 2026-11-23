// Runs the compiler's front end (src/browser_main.ab built for wasm32) in a worker or in Node: the browser host's imports over an
// in-memory file system. One compilation per instance: the compiler keeps its state in its own heap, so each compile starts from a
// fresh instance of the module the page compiled once.
import { Vfs, createSyscalls } from "./vfs.mjs";

// `stdlib`: Map<path under /stdlib, Uint8Array>; the compiler reads it at /stdlib/... (its toolchain root is "." and the working
// directory "/"). `files`: Map<path under /work, Uint8Array|string> for the program.
export function createBase(stdlibFiles) {
    const base = new Map();
    for (const [path, data] of stdlibFiles) base.set(`/stdlib/${path}`.replace(/\/+/g, "/"), data);
    return base;
}

export async function compile(module, base, files, entry = "main.ab") {
    const vfs = new Vfs(base);
    const encoder = new TextEncoder();
    for (const [path, data] of files) vfs.put(`/work/${path}`, typeof data === "string" ? encoder.encode(data) : data);
    let memory;
    const unknown = {};
    const output = { 1: "", 2: "" };
    const decoder = new TextDecoder();
    class Exit extends Error {
        constructor(code) { super(`exit ${code}`); this.code = code; }
    }
    const syscall = createSyscalls(vfs, () => memory, { unknown: (n) => { unknown[n] = (unknown[n] ?? 0) + 1; } });
    const abla_host = {
        syscall,
        write: (fd, data, length) => {
            data >>>= 0; length >>>= 0; // addresses above 2 GB arrive as negative i32
            // Descriptors 1 and 2 are the page's output; the others are files the compiler opened (system call 1 always reaches write).
            if (!(fd in output)) return Number(syscall(1n, BigInt(fd), BigInt(data), BigInt(length)));
            output[fd] += decoder.decode(new Uint8Array(memory.buffer, data, length));
            return length;
        },
        exit: (code) => { throw new Exit(code); },
        clock_ns: (clock) => (clock === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(performance.now() * 1e6))),
        random: (data, length) => { crypto.getRandomValues(new Uint8Array(memory.buffer, data >>> 0, length >>> 0)); return length; },
    };
    // C functions the compiler's process and string code name: no child process here, and strlen of a C string.
    const env = {
        fork: () => -1,
        strlen: (address) => { const heap = new Uint8Array(memory.buffer); let end = address >>> 0; while (heap[end]) end++; return end - (address >>> 0); },
    };
    const instance = await WebAssembly.instantiate(module, { abla_host, env });
    memory = instance.exports.memory;
    let status;
    try { status = instance.exports.main(); } catch (error) { if (error instanceof Exit) status = error.code; else throw error; }
    return { status, stdout: output[1], stderr: output[2], vfs, unknown };
}
