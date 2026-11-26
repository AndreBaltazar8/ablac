// The page's side of a compiled guest run (#1139 area 11): the guest worker runs the module's synchronous Wasm, which no code in the
// worker can interrupt, so the page ends a run that does not finish by terminating the worker. `while (true) {}` compiles to a guest and
// would otherwise hold a core for ever. One run per worker: the worker handles one message, and a fresh one is made for the next run.
export const guestDeadlineMilliseconds = 10000;

// The browser's worker: a module worker beside this file, which the page must serve from its own origin.
export function spawnBrowserGuestWorker(url = new URL("./guest-worker.mjs", import.meta.url)) {
    const worker = new Worker(url, { type: "module" });
    return {
        post: (message, transfer) => worker.postMessage(message, transfer),
        onMessage: (listener) => worker.addEventListener("message", ({ data }) => listener(data)),
        onError: (listener) => {
            worker.addEventListener("error", (event) => listener(event.message ?? "worker error"));
            worker.addEventListener("messageerror", () => listener("worker message error"));
        },
        terminate: () => worker.terminate(),
    };
}

// Runs `wasm` (the ArrayBuffer compileGuest returned; it is transferred, so the page keeps no copy) in a fresh guest worker with the
// remaining stdout budget, and answers { status, stdout, outputTruncated, memoryBytes } or { error } when the guest failed, or
// { timedOut: true, error } when it ran past `timeoutMilliseconds`: the worker is terminated, its output is lost.
export function runGuestWithDeadline(wasm, stdoutBudget, { timeoutMilliseconds = guestDeadlineMilliseconds, spawn = spawnBrowserGuestWorker } = {}) {
    return new Promise((resolve) => {
        let finished = false;
        const worker = spawn();
        const finish = (result) => {
            if (finished) return;
            finished = true;
            clearTimeout(timer);
            worker.terminate();
            resolve(result);
        };
        const timer = setTimeout(() => finish({ timedOut: true, error: `The program ran for more than ${timeoutMilliseconds / 1000} seconds and was stopped.` }), timeoutMilliseconds);
        worker.onMessage((data) => {
            // Only the worker's own two answers, and only their plain fields, reach the page.
            if (data?.type === "guest-result" && Number.isInteger(data.status) && typeof data.stdout === "string") {
                finish({ status: data.status, stdout: data.stdout, outputTruncated: data.outputTruncated === true, memoryBytes: Number(data.memoryBytes) || 0 });
            } else finish({ error: String(data?.message ?? "Unexpected message from the playground guest") });
        });
        worker.onError((message) => finish({ error: String(message) }));
        try {
            worker.post({ type: "run-guest", wasm, stdoutBudget }, [wasm]);
        } catch (error) {
            finish({ error: String(error) });
        }
    });
}
