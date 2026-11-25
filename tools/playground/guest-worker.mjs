import { runGuest } from "./guest.mjs";

self.addEventListener("message", async ({ data }) => {
    if (data?.type !== "run-guest") return;
    try {
        const result = await runGuest(data.wasm, data.stdoutBudget);
        self.postMessage({ type: "guest-result", ...result });
    } catch (error) {
        self.postMessage({ type: "guest-error", message: String(error) });
    }
}, { once: true });
