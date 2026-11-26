// Checks the guest's sandbox with modules written by hand (#1139 area 11), whatever the emitter would make: the sections and imports
// it admits, the bounded memory (initial, maximum, memory.grow), data segments and writes outside memory, module and budget
// limits, and the page's deadline for a guest that never finishes. No compiler is needed.
//   node guest-check.mjs
import { runGuest } from "./guest.mjs";
import { runGuestWithDeadline } from "./guest-host.mjs";
import { nodeGuestWorker } from "./node-guest-worker.mjs";

let failed = 0;
const check = (name, ok, detail = "") => {
    if (!ok) failed++;
    console.log(`${ok ? "ok  " : "FAIL"} ${name}${detail ? ": " + detail : ""}`);
};

const u = (value) => { const bytes = []; do { let digit = value & 127; value >>>= 7; bytes.push(value ? digit | 128 : digit); } while (value); return bytes; };
const s = (value) => { const bytes = []; for (;;) { const digit = value & 127; value >>= 7; if ((value === 0 && !(digit & 64)) || (value === -1 && (digit & 64))) { bytes.push(digit); return bytes; } bytes.push(digit | 128); } };
const section = (id, body) => [id, ...u(body.length), ...body];
const vec = (items) => [...u(items.length), ...items.flat()];
const name = (text) => [...u(text.length), ...Buffer.from(text)];
const op = { end: 11, loop: 3, br: 12, i32const: 65, call: 16, drop: 26, memoryGrow: [64, 0], unreachable: 0 };
// () -> i32 `main` with `body`, the write import (function 0), the emitter's own memory unless `memory` says otherwise.
function module({ body, memory = [1, 1, 1, 16], imports, extra = [], data = [], exportName = "main" }) {
    const bytes = [0, 97, 115, 109, 1, 0, 0, 0];
    bytes.push(...section(1, vec([[96, 2, 127, 127, 0], [96, 0, 1, 127]])));
    bytes.push(...section(2, imports ?? vec([[...name("abla_playground"), ...name("write"), 0, 0]])));
    bytes.push(...section(3, vec([[1]])));
    for (const [id, payload] of extra.filter(([id]) => id < 5)) bytes.push(...section(id, payload));
    bytes.push(...section(5, memory));
    for (const [id, payload] of extra.filter(([id]) => id >= 5 && id < 7)) bytes.push(...section(id, payload));
    bytes.push(...section(7, vec([[...name(exportName), 0, 1]])));
    for (const [id, payload] of extra.filter(([id]) => id >= 8 && id < 10)) bytes.push(...section(id, payload));
    bytes.push(...section(10, vec([[...u(body.length + 1), 0, ...body, op.end].length ? [...u(body.length + 2), 0, ...body, op.end] : []])));
    for (const [id, payload] of extra.filter(([id]) => id >= 10)) bytes.push(...section(id, payload));
    if (data.length) bytes.push(...section(11, data));
    return Uint8Array.from(bytes);
}
const returns = (value) => [op.i32const, ...s(value)];
const rejects = async (bytes, pattern) => {
    try { await runGuest(bytes); return false; } catch (error) { return pattern.test(error.message); }
};

// The baseline: main returns 7.
const baseline = await runGuest(module({ body: returns(7) }));
check("a hand-made module of the emitter's shape runs", baseline.status === 7 && baseline.stdout === "" && baseline.memoryBytes === 65536);
// Status is the low eight bits, as the CLI's exit status is.
const wide = await runGuest(module({ body: returns(300) }));
const negative = await runGuest(module({ body: returns(-1) }));
check("the status is the low eight bits of main's value (300 is 44, -1 is 255)", wide.status === 44 && negative.status === 255, `${wide.status} ${negative.status}`);

// Sections the guest never needs are refused: a table, a global, a start function, element and custom sections.
for (const [label, id, payload] of [["table", 4, vec([[112, 0, 1]])], ["global", 6, vec([[127, 0, ...returns(0), op.end]])], ["start", 8, u(1)], ["element", 9, vec([])], ["custom", 0, [...name("note")]], ["data count", 12, u(0)]]) {
    check(`a module with a ${label} section is refused`, await rejects(module({ body: returns(1), extra: [[id, payload]] }), /Unexpected Wasm section/));
}
// Imports: only the write function and the host's memory.
check("a second import is refused", await rejects(module({ body: returns(1), imports: vec([[...name("abla_playground"), ...name("write"), 0, 0], [...name("env"), ...name("fetch"), 0, 0]]) }), /Unexpected playground guest imports/));
check("a foreign function name is refused", await rejects(module({ body: returns(1), imports: vec([[...name("env"), ...name("fetch"), 0, 0]]) }), /Unexpected playground guest imports|LinkError|link/i));
check("an export other than main is refused", await rejects(module({ body: returns(1), exportName: "other" }), /Unexpected playground guest imports or exports/));

// Memory: at most 16 pages whatever the module declares, and memory.grow stops there.
const growBy = (pages) => [op.i32const, ...s(pages), ...op.memoryGrow];
const grown = await runGuest(module({ body: [...growBy(15), op.drop, ...growBy(1)] }));
check("memory.grow past 16 pages gives -1 (255) and the memory stays at 16 pages", grown.status === 255 && grown.memoryBytes === 16 * 65536, JSON.stringify(grown));
const allowed = await runGuest(module({ body: growBy(15) }));
check("memory.grow within 16 pages works (returns the old size, 1)", allowed.status === 1 && allowed.memoryBytes === 16 * 65536);
const unbounded = await runGuest(module({ body: growBy(100), memory: [1, 0, 1] }));
check("a memory declared with no maximum is capped at 16 pages", unbounded.status === 255 && unbounded.memoryBytes === 65536, JSON.stringify(unbounded));
const huge = await runGuest(module({ body: growBy(100), memory: [1, 1, 1, ...u(65536)] }));
check("a declared maximum of 65536 pages is capped at 16", huge.status === 255 && huge.memoryBytes === 65536, JSON.stringify(huge));
check("more than 16 initial pages is refused", await rejects(module({ body: returns(1), memory: [1, 1, 17, 17] }), /memory-limit/));
check("a shared or 64-bit memory is refused", await rejects(module({ body: returns(1), memory: [1, 3, 1, 1] }), /unshared wasm32 memory/) &&
    await rejects(module({ body: returns(1), memory: [1, 4, 1] }), /unshared wasm32 memory/));
check("two memories are refused", await rejects(module({ body: returns(1), memory: [2, 0, 1, 0, 1] }), /one unshared wasm32 memory/));

// Data segments: inside memory they are written, past it the module does not instantiate.
const segment = (offset, bytes) => vec([[0, 65, ...s(offset), 11, ...u(bytes.length), ...bytes]]);
const inside = await runGuest(module({ body: returns(1), data: segment(65528, [1, 2, 3, 4, 5, 6, 7, 8]) }));
check("a data segment ending at the end of memory is accepted", inside.status === 1);
for (const [label, offset, size] of [["one byte past", 65529, 8], ["far past", 1 << 30, 4], ["at a negative offset", -1, 4]]) {
    check(`a data segment ${label} the end of memory does not instantiate`, await rejects(module({ body: returns(1), data: segment(offset, new Array(size).fill(1)) }), /./));
}

// Writes: the pointer and length are unsigned 32-bit values checked against the current memory.
const callWrite = (pointer, count) => [op.i32const, ...s(pointer), op.i32const, ...s(count), op.call, 0];
const text = await runGuest(module({ body: [...callWrite(0, 3), ...returns(0)], data: segment(0, [104, 105, 10]) }));
check("a write inside memory is kept", text.stdout === "hi\n" && text.status === 0);
for (const [label, pointer, count] of [["past the end", 65535, 2], ["with a huge length", 0, -1], ["at a negative pointer", -1, 1], ["one past the end", 65536, 1]]) {
    check(`a write ${label} stops the guest`, await rejects(module({ body: [...callWrite(pointer, count), ...returns(0)] }), /outside linear memory/));
}
const emptyAtEnd = await runGuest(module({ body: [...callWrite(65536, 0), ...returns(3)] }));
check("an empty write at the end of memory is allowed", emptyAtEnd.status === 3);
const budgeted = await runGuest(module({ body: [...callWrite(0, 3), ...returns(0)], data: segment(0, [104, 105, 10]) }), 2);
check("a write past the stdout budget is cut and reported", budgeted.outputTruncated && budgeted.stdout === "hi" && budgeted.status === 1);

// Inputs: sizes and types.
check("a module over 1 MiB is refused", await rejects(new Uint8Array((1 << 20) + 1), /Invalid playground guest module size/));
for (const [label, value] of [["a string", "(module)"], ["a plain object", {}], ["null", null]]) {
    check(`${label} as the module is refused`, await rejects(value, /Invalid playground guest module size/));
}
check("a stdout budget above the limit or fractional is refused", await (async () => {
    for (const budget of [1048577, -1, 1.5, NaN]) { try { await runGuest(module({ body: returns(1) }), budget); return false; } catch (error) { if (!/budget/.test(error.message)) return false; } }
    return true;
})());
check("a module with a bad header or a truncated section is refused", await rejects(Uint8Array.of(0, 97, 115, 109, 2, 0, 0, 0), /Invalid Wasm header/) &&
    await rejects(Uint8Array.from([0, 97, 115, 109, 1, 0, 0, 0, 1, 50, 1]), /Truncated Wasm section/));

// The deadline: a guest that never finishes is stopped by terminating its worker (Node's worker with the page's worker API).
// A run that never answers (a deadline that does not fire) must fail this check, not hang it.
const within = (promise, milliseconds) => Promise.race([promise, new Promise((resolve) => setTimeout(() => resolve({ hung: true }), milliseconds))]);
// Every run ends by terminating its worker (a worker left running would keep a core busy after the page has its answer).
let terminations = 0;
const countingWorker = () => { const worker = nodeGuestWorker(); return { ...worker, terminate: () => { terminations++; return worker.terminate(); } }; };
const forever = module({ body: [op.loop, 64, op.br, 0, op.end, ...returns(0)] });
const started = Date.now();
const stopped = await within(runGuestWithDeadline(forever.buffer.slice(0), 1048576, { timeoutMilliseconds: 600, spawn: countingWorker }), 5000);
check("a guest that never finishes is stopped at the deadline", stopped.timedOut === true && /stopped/.test(stopped.error) && Date.now() - started < 5000, JSON.stringify(stopped));
const finished = await runGuestWithDeadline(module({ body: returns(9) }).buffer.slice(0), 1048576, { timeoutMilliseconds: 5000, spawn: countingWorker });
check("a guest that finishes answers through the worker", finished.status === 9 && finished.timedOut === undefined && finished.stdout === "", JSON.stringify(finished));
const failedRun = await runGuestWithDeadline(module({ body: [...callWrite(65535, 2), ...returns(0)] }).buffer.slice(0), 1048576, { timeoutMilliseconds: 5000, spawn: countingWorker });
check("a guest that fails answers with the error, not a result", /outside linear memory/.test(failedRun.error ?? "") && failedRun.status === undefined, JSON.stringify(failedRun));

check("each run terminated its worker (three runs)", terminations === 3, String(terminations));

process.exit(failed ? 1 : 0);
