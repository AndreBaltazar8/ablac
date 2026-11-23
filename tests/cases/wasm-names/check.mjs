// argv: <plain.wasm> <names.wasm>
// --wasm-names adds the name section (the functions' names) to a release module, with the target_features section Binaryen then keeps; every other section, the code section
// included, is the same bytes as the plain module's.
import { readFileSync } from "node:fs";
const [plainPath, namesPath] = process.argv.slice(2);
const sections = (path) => {
    const bytes = readFileSync(path);
    const result = [];
    let at = 8;
    const leb = () => { let value = 0, shift = 0, byte; do { byte = bytes[at++]; value |= (byte & 127) << shift; shift += 7; } while (byte & 128); return value; };
    while (at < bytes.length) {
        const id = bytes[at++];
        const size = leb();
        const start = at;
        let name = "";
        if (id === 0) { const length = leb(); name = bytes.subarray(at, at + length).toString("utf8"); at = start; }
        result.push({ id, name, body: bytes.subarray(start, start + size) });
        at = start + size;
    }
    return result;
};
const fail = (why) => { throw new Error(`wasm names: ${why}`); };
const plain = sections(plainPath);
const named = sections(namesPath);
const nameOf = (list) => list.filter((section) => section.id === 0 && section.name === "name");
if (nameOf(plain).length !== 0) fail("the plain module has a name section");
if (nameOf(named).length !== 1) fail("the --wasm-names module has no name section");
const rest = (list) => list.filter((section) => !(section.id === 0 && (section.name === "name" || section.name === "target_features")));
const a = rest(plain), b = rest(named);
if (a.length !== b.length) fail(`the sections differ: ${a.length} against ${b.length}`);
for (let index = 0; index < a.length; index++) {
    if (a[index].id !== b[index].id || a[index].name !== b[index].name || !a[index].body.equals(b[index].body)) {
        fail(`section ${index} (id ${a[index].id} ${a[index].name}) differs`);
    }
}
const code = a.findIndex((section) => section.id === 10);
if (code < 0) fail("no code section");
const names = Buffer.from(nameOf(named)[0].body).toString("latin1");
if (!/crash\.crash/.test(names)) fail("the name section names no crash.crash");
if (!/__ablaRuntimePanic/.test(names)) fail("the name section names no panic function");
console.log(`name section ${nameOf(named)[0].body.length} bytes, ${a.length} other sections identical`);
