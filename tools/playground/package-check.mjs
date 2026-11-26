// Checks an unpacked abla-playground package from its own files, as a page would use it:
//   node package-check.mjs <unpacked directory> [size limits JSON]
// The manifest's sizes and hashes match the files, the stdlib bundle loads over HTTP (served with Content-Encoding: br, as the site does), the
// module compiles, and the host runs a program with the compiler's evaluator.
import { createHash } from "node:crypto";
import { createServer } from "node:http";
import { readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";
import { promisify } from "node:util";
import { brotliCompress, constants } from "node:zlib";

const [directory, limitsJson = "{}"] = process.argv.slice(2);
const limits = { wasmBytes: 8 * 1048576, wasmBrotliBytes: 2 * 1048576, stdlibBytes: 1.2 * 1048576, ...JSON.parse(limitsJson) };
const fail = (message) => { console.error(`playground package: ${message}`); process.exit(1); };
const manifest = JSON.parse(readFileSync(join(directory, "manifest.json"), "utf8"));
if (manifest.format !== 1) fail(`unknown manifest format ${manifest.format}`);

for (const entry of [manifest.compiler, manifest.stdlib, ...manifest.host]) {
    const bytes = readFileSync(join(directory, entry.file));
    if (bytes.length !== entry.bytes) fail(`${entry.file} is ${bytes.length} bytes, the manifest says ${entry.bytes}`);
    if (createHash("sha256").update(bytes).digest("hex") !== entry.sha256) fail(`${entry.file} does not match its hash`);
}
if (!manifest.compiler.file.includes(manifest.compiler.sha256.slice(0, 16))) fail("the module's name does not carry its hash");
if (!manifest.stdlib.file.includes(manifest.stdlib.sha256)) fail("the bundle's name does not carry its hash");

const wasm = readFileSync(join(directory, manifest.compiler.file));
if (wasm.length > limits.wasmBytes) fail(`the module is ${wasm.length} bytes, over ${limits.wasmBytes}`);
if (manifest.stdlib.bytes > limits.stdlibBytes) fail(`the stdlib bundle is ${manifest.stdlib.bytes} bytes, over ${limits.stdlibBytes}`);

// Compress on a worker while the main thread validates and runs the Wasm.
const compressedSize = promisify(brotliCompress)(wasm, {
    params: { [constants.BROTLI_PARAM_QUALITY]: 11, [constants.BROTLI_PARAM_SIZE_HINT]: wasm.length },
}).then(bytes => {
    if (bytes.length > limits.wasmBrotliBytes) fail(`the module is ${bytes.length} bytes with brotli, over ${limits.wasmBrotliBytes}`);
    return bytes.length;
}, error => fail(`Brotli compression failed: ${error.message}`));

const server = createServer((request, response) => {
    const file = join(directory, request.url.slice(1));
    try {
        const body = readFileSync(file);
        const headers = { "Content-Type": "application/octet-stream" };
        if (file.endsWith(".br")) headers["Content-Encoding"] = "br";
        response.writeHead(200, headers);
        response.end(body);
    } catch { response.writeHead(404); response.end(); }
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
try {
    const { loadStdlib } = await import(pathToFileURL(join(directory, "stdlib-bundle.mjs")));
    const host = await import(pathToFileURL(join(directory, "host.mjs")));
    const stdlib = await loadStdlib(`http://127.0.0.1:${server.address().port}/${manifest.stdlib.file}`);
    const module = await WebAssembly.compile(wasm);
    const source = 'import "abla/io"\n\nfun main: int {\n    println("package ok")\n    7\n}\n';
    const base = host.createBase(stdlib);
    const run = (source, files = []) => host.run(module, base, new Map([["main.ab", source], ...files]));
    const result = await run(source);
    if (!result.ok || result.stdout !== "package ok\n" || result.status !== 7) fail(`the program ran as ${JSON.stringify({ ok: result.ok, status: result.status, stdout: result.stdout, diagnostics: result.diagnostics.slice(0, 200) })}`);
    // The bounded module the page loads (its memory comes from the host, capped) runs the same program.
    const boundedModule = await host.boundedCompiler(wasm);
    const boundedRun = await host.run(boundedModule, base, new Map([["main.ab", source]]));
    if (!boundedRun.ok || boundedRun.stdout !== "package ok\n" || boundedRun.status !== 7) fail(`the bounded module ran as ${JSON.stringify({ ok: boundedRun.ok, status: boundedRun.status, stdout: boundedRun.stdout })}`);
    if (manifest.host.some(entry => entry.file === "guest-worker.mjs")) {
        const { runGuest } = await import(pathToFileURL(join(directory, "guest.mjs")));
        const compiled = await host.compileGuest(boundedModule, base, new Map([["main.ab", source]]));
        if (!compiled.ok) fail(`the packed direct emitter failed: ${compiled.stderr}`);
        const guest = await runGuest(compiled.wasm, compiled.stdoutBudget);
        if (guest.status !== 7 || guest.stdout !== "package ok\n" || guest.memoryBytes !== 65536) {
            fail(`the packed direct guest ran as ${JSON.stringify(guest)}`);
        }
    }
    for (const [signature, tail, status] of [["fun main(): i64", "7", 7], ["fun main", "return", 0]]) {
        const output = await run(`import "abla/io"\n${signature} { println("main ran"); ${tail} }\n`);
        if (!output.ok || output.status !== status || output.stdout !== "main ran\n") {
            fail(`${signature} should report status ${status}: ${JSON.stringify(output)}`);
        }
    }
    for (const [source, reason] of [
        ['import "abla/fs"\nfun main(): int = path("notes.txt").readText().size\n', "compile.effect-denied:"],
        ['import "abla/compiler"\n#compilerGrant("filesystem.read")\nfun main: int = 0\n', "compile.capability-not-authorized:filesystem.read"],
    ]) {
        const denied = await run(source);
        if (denied.ok || denied.status !== 1 || !denied.diagnostics.includes(reason) ||
            !denied.diagnostics.includes("Run this program locally with ablac run main.ab")) {
            fail(`missing local-run guidance for ${reason} in ${denied.diagnostics}`);
        }
    }
    const importsPricing = 'import "pricing.ab" as pricing\nfun main(): int = pricing.price()\n';
    const pricing = ["pricing.ab", "fun price(): int = 7\n"];
    const hint = "This run received only the editor file";
    const missing = await run(importsPricing);
    if (missing.ok || !missing.diagnostics.includes("E_IMPORT_NOT_FOUND") || !missing.diagnostics.includes(hint)) {
        fail(`missing companion-file guidance in ${missing.diagnostics}`);
    }
    const supplied = await run(importsPricing, [pricing]);
    if (!supplied.ok || supplied.status !== 7 || supplied.diagnostics.includes(hint)) {
        fail(`the companion file did not resolve: ${JSON.stringify(supplied)}`);
    }
    const missingStdlib = await run('import "abla/missing_playground_module"\nfun main: int = 0\n');
    if (missingStdlib.ok || !missingStdlib.diagnostics.includes("E_IMPORT_NOT_FOUND") || missingStdlib.diagnostics.includes(hint)) {
        fail(`unexpected companion-file guidance for a missing standard module: ${missingStdlib.diagnostics}`);
    }
    const brotli = await compressedSize;
    console.log(`playground package ${manifest.version}: module ${(wasm.length / 1048576).toFixed(2)} MB (${(brotli / 1048576).toFixed(2)} MB brotli), stdlib bundle ${(manifest.stdlib.bytes / 1048576).toFixed(2)} MB; hashes match, the bundle loads over HTTP, a program runs`);
} finally {
    server.close();
}
