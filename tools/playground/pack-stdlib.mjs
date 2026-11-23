// Usage: node tools/playground/pack-stdlib.mjs <stdlib directory> <output directory>
import { createHash } from "node:crypto";
import { mkdir, mkdtemp, readFile, readdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { brotliCompressSync, constants } from "node:zlib";

const [root, output] = process.argv.slice(2);
if (!root || !output || process.argv.length !== 4) {
    console.error("Usage: node tools/playground/pack-stdlib.mjs <stdlib directory> <output directory>");
    process.exit(2);
}

const files = [];
const contents = [];
async function collect(directory) {
    const entries = await readdir(join(root, directory), { withFileTypes: true });
    entries.sort((left, right) => left.name === right.name ? 0 : left.name < right.name ? -1 : 1);
    for (const entry of entries) {
        const { name } = entry;
        const path = directory ? directory + "/" + name : name;
        if (name.includes("\\")) throw new Error(`Invalid stdlib path: ${path}`);
        if (entry.isDirectory()) {
            await collect(path);
        } else {
            if (!entry.isFile()) throw new Error(`Expected a regular stdlib file: ${path}`);
            const bytes = await readFile(join(root, path));
            files.push([path, bytes.length]);
            contents.push(bytes);
        }
    }
}

await collect("");
if (files.length === 0) throw new Error("The stdlib directory is empty");
// The little-endian index length precedes the UTF-8 JSON index. File bytes
// follow in index order, so offsets are derived from the preceding lengths.
const index = Buffer.from(JSON.stringify({ version: 1, files }));
const header = Buffer.alloc(4);
header.writeUInt32LE(index.length);
const compressed = brotliCompressSync(Buffer.concat([header, index, ...contents]), {
    params: { [constants.BROTLI_PARAM_QUALITY]: 9 },
});
const hash = createHash("sha256").update(compressed).digest("hex");
const filename = `stdlib-${hash}.bin.br`;
await mkdir(output, { recursive: true });
const scratch = await mkdtemp(join(output, ".stdlib-"));
try {
    await writeFile(join(scratch, filename), compressed);
    await rename(join(scratch, filename), join(output, filename));
} finally {
    await rm(scratch, { recursive: true, force: true });
}
console.log(filename);
