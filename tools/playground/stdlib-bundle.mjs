const bundles = new Map();
const decoder = new TextDecoder("utf-8", { fatal: true });

function unpack(buffer) {
    if (buffer.byteLength < 4) throw new Error("Missing stdlib index length");
    const bytes = new Uint8Array(buffer);
    const end = 4 + new DataView(buffer).getUint32(0, true);
    if (end > bytes.length) throw new Error("Truncated stdlib index");
    const index = JSON.parse(decoder.decode(bytes.subarray(4, end)));
    if (index?.version !== 1 || !Array.isArray(index.files)) throw new Error("Unsupported stdlib index");
    const files = new Map();
    let position = end;
    for (const item of index.files) {
        if (!Array.isArray(item) || item.length !== 2) throw new Error("Invalid stdlib index entry");
        const [path, length] = item;
        if (typeof path !== "string" || /[\\\0]/u.test(path) ||
            path.split("/").some((part) => part === "" || part === "." || part === "..") ||
            files.has(path)) throw new Error("Invalid or duplicate stdlib path");
        if (!Number.isSafeInteger(length) || length < 0 || length > bytes.length - position) {
            throw new Error(`Invalid stdlib file length: ${path}`);
        }
        files.set(path, bytes.subarray(position, position + length));
        position += length;
    }
    if (position !== bytes.length) throw new Error("Unexpected bytes after stdlib files");
    return files;
}

async function fetchBundle(url) {
    const response = await fetch(url);
    if (!response.ok || !response.body) throw new Error(`Could not fetch stdlib bundle (HTTP ${response.status})`);
    // Fetch already decodes HTTP Brotli. Raw .br downloads use the browser's
    // Brotli stream when present. HTTP encoding also works in Chromium.
    if (response.headers.get("content-encoding")?.trim().toLowerCase() === "br") {
        return unpack(await response.arrayBuffer());
    }
    let brotli;
    try {
        brotli = new DecompressionStream("brotli");
    } catch {
        throw new Error("This browser needs the stdlib bundle served with Content-Encoding: br");
    }
    return unpack(await new Response(response.body.pipeThrough(brotli)).arrayBuffer());
}

/** Returns one shared map of relative paths to read-only byte views per bundle URL. */
export function loadStdlib(bundleUrl) {
    const url = String(bundleUrl);
    if (!bundles.has(url)) {
        bundles.set(url, fetchBundle(url).catch((error) => {
            bundles.delete(url);
            throw error;
        }));
    }
    return bundles.get(url);
}
