const defaults = { ms: 2000, outputBytes: 65536, memoryPages: 1024 };

export function runLimits(limits = {}) {
    const result = {};
    for (const [name, fallback] of Object.entries(defaults)) {
        const value = limits[name] ?? fallback;
        const max = name === "memoryPages" ? 65536 : 0x7fffffff;
        if (!Number.isInteger(value) || value <= 0 || value > max) {
            throw new Error(`Invalid run limit: ${name}`);
        }
        result[name] = value;
    }
    return result;
}

/**
 * Pass a Wasm ArrayBuffer, with optional args, env, stdin, files and limits.
 * The virtual preopen starts with the given relative filenames and text values.
 * The buffer is transferred. Output arrives as {type: "stdout" or "stderr", text}.
 * The promise resolves with {type: "exit", code} or {type: "exit", trap}.
 * Each run gets its own worker and a watchdog outside the guest's thread.
 */
export function runProgram(request, onOutput = () => {}, makeWorker = () =>
    new Worker(new URL("./run-worker.mjs", import.meta.url), { type: "module" })) {
    const limits = runLimits(request.limits);
    return new Promise((resolve) => {
        const worker = makeWorker();
        let finished = false;
        const timer = setTimeout(() => finish({ type: "exit", trap: "timeout" }), limits.ms);
        function finish(exit) {
            if (finished) return;
            finished = true;
            clearTimeout(timer);
            worker.terminate();
            resolve(exit);
        }
        worker.addEventListener("message", ({ data }) => {
            if (finished) return;
            if (data.type === "exit") finish(data);
            else onOutput(data);
        });
        worker.addEventListener("error", (event) => {
            event.preventDefault?.();
            finish({ type: "exit", trap: event.message || "worker error" });
        });
        try {
            worker.postMessage({ ...request, type: "run", limits }, [request.wasm]);
        } catch (error) {
            finish({ type: "exit", trap: error.message });
        }
    });
}
