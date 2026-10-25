// Prints a module's imports (one per line, "module.name") and then whether it
// has a tag section (exception handling), "tags" or "no tags".
import { readFileSync } from "node:fs";

const bytes = readFileSync(process.argv[2]);
const module = new WebAssembly.Module(bytes);
for (const entry of WebAssembly.Module.imports(module)) console.log(`${entry.module}.${entry.name}`);
let offset = 8;
let tags = false;
const leb = () => {
    let value = 0, shift = 0, byte;
    do { byte = bytes[offset++]; value |= (byte & 0x7f) << shift; shift += 7; } while (byte & 0x80);
    return value;
};
while (offset < bytes.length) {
    const id = bytes[offset++];
    const size = leb();
    if (id === 13) tags = true;
    offset += size;
}
console.log(tags ? "tags" : "no tags");
