// A Node worker_threads Worker with the page's worker API, so guest-host.mjs can be checked under Node (tools/playground/guest-check.mjs).
import { Worker } from "node:worker_threads";

const workerUrl = new URL("./guest-worker.mjs", import.meta.url).href;

export function nodeGuestWorker() {
    const code = `import { parentPort } from "node:worker_threads";
globalThis.self = { addEventListener: (type, listener) => parentPort.on("message", (data) => listener({ data })), postMessage: (message) => parentPort.postMessage(message) };
await import(${JSON.stringify(workerUrl)});`;
    const worker = new Worker(code, { eval: true });
    return {
        post: (message, transfer) => worker.postMessage(message, transfer),
        onMessage: (listener) => worker.on("message", listener),
        onError: (listener) => worker.on("error", (error) => listener(error.message)),
        terminate: () => worker.terminate(),
    };
}
