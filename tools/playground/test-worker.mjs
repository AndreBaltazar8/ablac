import { parentPort } from "node:worker_threads";

// The production module speaks browser Worker events. Translate only the
// transport so the Node tests run the same worker and host code.
globalThis.addEventListener = (name, listen) => {
    if (name !== "message") throw new Error(name);
    parentPort.on("message", (data) => listen({ data }));
};
globalThis.postMessage = (data) => parentPort.postMessage(data);
await import("./run-worker.mjs");
