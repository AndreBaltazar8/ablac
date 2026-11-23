import { runLimits } from "./run.mjs";
import { withBoundedMemory } from "./wasm-memory.mjs";
import { wasiHost } from "./wasi-preview1.mjs";

async function run(request, post) {
    let host;
    let result;
    try {
        const limits = runLimits(request.limits);
        if (!(request.wasm instanceof ArrayBuffer)) throw new Error("Expected Wasm bytes");
        const capped = withBoundedMemory(request.wasm, limits.memoryPages);
        const module = await WebAssembly.compile(capped.binary);
        if (!WebAssembly.Module.exports(module).some(({ name, kind }) =>
            name === "_start" && kind === "function")) throw new Error("Missing WASI _start");
        const imports = WebAssembly.Module.imports(module);
        const memories = imports.filter(({ kind }) => kind === "memory");
        if (memories.length !== 1 || memories[0].module !== "env" || memories[0].name !== "memory") {
            throw new Error("Expected only the playground memory import");
        }
        const memory = new WebAssembly.Memory({ initial: capped.initial, maximum: capped.maximum });
        host = wasiHost(memory, request, limits, post);
        for (const entry of imports) {
            if (entry.kind === "memory") continue;
            if (entry.kind !== "function" || entry.module !== "wasi_snapshot_preview1" ||
                !Object.hasOwn(host.imports, entry.name)) {
                throw new Error(`Unsupported import: ${entry.module}.${entry.name}`);
            }
        }
        const instance = await WebAssembly.instantiate(module, {
            env: { memory }, wasi_snapshot_preview1: host.imports,
        });
        instance.exports._start();
        result = { type: "exit", code: 0 };
    } catch (error) {
        result = host?.exit(error) ?? { type: "exit", trap: error.message || String(error) };
    }
    host?.flush();
    post(result);
}

let started = false;
globalThis.addEventListener("message", ({ data }) => {
    if (started || data?.type !== "run") return;
    started = true;
    void run(data, (message) => globalThis.postMessage(message));
});
