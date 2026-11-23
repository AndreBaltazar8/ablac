import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { Worker } from "node:worker_threads";
import { runProgram } from "./run.mjs";

async function run(name, options = {}) {
    const input = await readFile(path.join(process.argv[2], name + ".wasm"));
    const wasm = input.buffer.slice(input.byteOffset, input.byteOffset + input.byteLength);
    const messages = [];
    let terminated;
    const exit = await runProgram({ wasm, ...options }, (message) => messages.push(message), () => {
        const worker = new Worker(new URL("./test-worker.mjs", import.meta.url));
        return {
            addEventListener(type, listener) {
                if (type === "message") worker.on(type, (data) => listener({ data }));
                else worker.on(type, listener);
            },
            postMessage: (message, transfer) => worker.postMessage(message, transfer),
            terminate: () => { terminated = worker.terminate(); },
        };
    });
    assert.ok(terminated, "every run must terminate its worker");
    await terminated;
    assert.equal(wasm.byteLength, 0, "the guest bytes were transferred to the worker");
    const stream = (type) => messages.filter((message) => message.type === type)
        .map(({ text }) => text).join("");
    return { exit, stdout: stream("stdout"), stderr: stream("stderr"), messages };
}

const hello = await run("hello", {
    args: ["two words ☃"],
    env: { PLAYGROUND: "preview" },
    stdin: "input line\n",
});
assert.deepEqual(hello.exit, { type: "exit", code: 7 });
assert.equal(hello.stdout, "hello from the worker\ntwo words ☃\npreview\n");
assert.equal(hello.stderr, "input line\n");
assert.ok(hello.messages.filter(({ type }) => type === "stdout").length > 1);

const files = await run("files", { files: { "fixture/input.txt": "seed" } });
assert.deepEqual(files.exit, { type: "exit", code: 0 });
assert.equal(files.stdout, "seed + output\n");

const loop = await run("loop", { limits: { ms: 800 } });
assert.equal(loop.stdout, "loop started\n");
assert.deepEqual(loop.exit, { type: "exit", trap: "timeout" });

const enough = await run("memory", { limits: { memoryPages: 96 } });
assert.deepEqual(enough.exit, { type: "exit", code: 0 });
assert.equal(enough.stdout, "allocating\n42\n");

const tooSmall = await run("memory", { limits: { memoryPages: 24 } });
assert.equal(tooSmall.stdout, "allocating\n");
assert.equal(tooSmall.exit.type, "exit");
assert.match(tooSmall.exit.trap, /unreachable|memory/i);

const invalid = await run("hello", { limits: { memoryPages: 1 } });
assert.deepEqual(invalid.exit, { type: "exit", trap: "memory-limit" });

const output = await run("hello", { limits: { outputBytes: 4 } });
assert.equal(output.stdout, "hell");
assert.deepEqual(output.exit, { type: "exit", trap: "output-limit" });
process.stdout.write("Playground runner: streaming, preopen, exit status, watchdog, memory and output caps passed\n");
