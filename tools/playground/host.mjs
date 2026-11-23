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

export async function compile(module, base, files, options = {}) {
    const vfs = new Vfs(base);
    const encoder = new TextEncoder();
    // The program lives in /work (its project, and the working directory) unless `root` says another directory; "/" puts it at the file system root.
    const root = options.root ?? "/work"; // (`cwd` is the working directory, `root` by default)
    const at = (path) => (root === "/" ? `/${path}` : `${root}/${path}`);
    for (const [path, data] of files) vfs.put(at(path), typeof data === "string" ? encoder.encode(data) : data);
    let memory;
    const unknown = {};
    const output = { 1: "", 2: "" };
    const decoder = new TextDecoder();
    class Exit extends Error {
        constructor(code) { super(`exit ${code}`); this.code = code; }
    }
    if (options.entry) vfs.put("/work/entry", encoder.encode(at(options.entry)));
    const fileCalls = createSyscalls(vfs, () => memory, { cwd: options.cwd ?? root, stdin: options.stdin, unknown: (n) => { unknown[n] = (unknown[n] ?? 0) + 1; } });
    const heap = () => new Uint8Array(memory.buffer);
    const address = (value) => Number(BigInt.asUintN(32, BigInt(value)));
    // The module's one host import, abla_host.syscall: the calls that leave the file system are the page's (output, exit, the clocks,
    // random bytes); the rest are files.
    const syscall = (number, a0, a1, a2, a3, a4, a5) => {
        switch (Number(number)) {
            case 1: { // write: descriptors 1 and 2 are the page's output, the others files
                const fd = Number(a0);
                if (!(fd in output)) break;
                const length = Number(a2);
                output[fd] += decoder.decode(heap().subarray(address(a1), address(a1) + length));
                return BigInt(length);
            }
            case 60: case 231: throw new Exit(Number(a0));
            case 228: { // clock_gettime(clock, timespec): the real-time clock is the wall clock, the others the monotonic one
                const nanoseconds = Number(a0) === 0 ? BigInt(Date.now()) * 1000000n : BigInt(Math.round(performance.now() * 1e6));
                const view = new DataView(memory.buffer);
                view.setBigInt64(address(a1), nanoseconds / 1000000000n, true);
                view.setBigInt64(address(a1) + 8, nanoseconds % 1000000000n, true);
                return 0n;
            }
            case 318: crypto.getRandomValues(heap().subarray(address(a0), address(a0) + Number(a1))); return a1;
        }
        return fileCalls(number, a0, a1, a2, a3, a4, a5);
    };
    const abla_host = { syscall };
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

// Runs a program with the compiler's evaluator: a wrapper module calls the program's `main` at compile time (a `#` site), so the program's
// output is the compiler's, on descriptor 1 and 2, and its result the exit status. Only the clock, random and process.io grants (standard input; no process can start here): no files or
// network. `files` has the program's main.ab; `stdin` is a string or bytes. Returns {status, stdout, stderr, diagnostics}.
export async function run(module, base, files, { stdin = "" } = {}) {
    const source = files.get("main.ab");
    const text = typeof source === "string" ? source : new TextDecoder().decode(source);
    const returnsInt = /^fun\s+main\s*(\(\s*\))?\s*:\s*int\b/m.test(text);
    const call = returnsInt ? "val result = user.main()\n    eprintln(\"exit=$result\")\n    result" : "user.main()\n    eprintln(\"exit=0\")\n    0";
    const wrapper = `import "abla/io"\nimport "abla/compiler"\n#compilerGrant("clock")\n#compilerGrant("random")\n#compilerGrant("process.io")\nimport "./main.ab" as user\n\nfun evalWrap: int {\n    ${call}\n}\n\nval evalCode = #evalWrap()\n\nfun main: int = 0\n`;
    const all = new Map(files);
    all.set("eval.ab", wrapper);
    all.set("abla.toml", 'compileCapabilities = ["clock", "random", "process.io"]\n');
    const result = await compile(module, base, all, { entry: "eval.ab", stdin: typeof stdin === "string" ? new TextEncoder().encode(stdin) : stdin });
    const exit = /^exit=(-?\d+)$/m.exec(result.stderr);
    const diagnostics = result.stderr.split("\n").filter((line) => !/^(exit=|lowered:|errors=)/.test(line)).join("\n").trim();
    const ok = exit !== null && /errors=0 /.test(result.stderr);
    return { status: ok ? Number(exit[1]) : 1, stdout: result.stdout, stderr: result.stderr, diagnostics, ok };
}
