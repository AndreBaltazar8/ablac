// Exercise the real packer and both Fetch decoding paths under Node.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { once } from "node:events";
import { mkdtemp, readFile, readdir, rm } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { loadStdlib } from "./stdlib-bundle.mjs";

const root = resolve(process.argv[2] ?? "stdlib");
const scratch = await mkdtemp(join(tmpdir(), "abla-stdlib-test-"));
const packer = fileURLToPath(new URL("./pack-stdlib.mjs", import.meta.url));
let server;
try {
    const pack = () => execFileSync(process.execPath, [packer, root, scratch], { encoding: "utf8" }).trim();
    const filename = pack();
    assert.equal(pack(), filename, "pack must be reproducible");
    const compressed = await readFile(join(scratch, filename));
    assert.equal(filename, `stdlib-${createHash("sha256").update(compressed).digest("hex")}.bin.br`);

    const requests = [];
    server = createServer((request, response) => {
        requests.push(request.url);
        const headers = { "Content-Type": "application/octet-stream", "Cache-Control": "public, max-age=31536000, immutable" };
        if (request.url === "/encoded/" + filename) headers["Content-Encoding"] = "br";
        response.writeHead(200, headers).end(compressed);
    });
    server.listen(0, "127.0.0.1");
    await once(server, "listening");
    const base = "http://127.0.0.1:" + server.address().port;
    const rawUrl = new URL("/raw/" + filename, base);
    const encodedUrl = new URL("/encoded/" + filename, base);
    const pending = loadStdlib(rawUrl);
    assert.strictEqual(loadStdlib(rawUrl), pending);
    const [raw, encoded] = await Promise.all([pending, loadStdlib(encodedUrl)]);
    assert.strictEqual(await loadStdlib(rawUrl), raw);
    assert.deepEqual(requests.sort(), [encodedUrl.pathname, rawUrl.pathname].sort());

    const files = (await readdir(root, { recursive: true, withFileTypes: true }))
        .filter((entry) => entry.isFile());
    assert.equal(raw.size, files.length);
    assert.equal(encoded.size, files.length);
    for (const entry of files) {
        const path = join(entry.parentPath, entry.name);
        const name = relative(root, path).replaceAll("\\", "/");
        const bytes = await readFile(path);
        assert.deepEqual(raw.get(name), new Uint8Array(bytes), name);
        assert.deepEqual(encoded.get(name), new Uint8Array(bytes), name);
    }
    console.log(`stdlib bundle: ${files.length} files, ${compressed.length} Brotli bytes, both decoders and shared fetch checked`);
} finally {
    if (server) {
        server.close();
        server.closeAllConnections();
    }
    await rm(scratch, { recursive: true, force: true });
}
