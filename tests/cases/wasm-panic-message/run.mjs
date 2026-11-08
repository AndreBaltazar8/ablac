// argv: <directory with <name>-<mode>.wasm> <name> <mode>
// A panic writes "panic: <message>" to fd 2 through abla_host.write when the
// module imports it for other reasons, and adds no import otherwise.
import { readFileSync } from "node:fs";
const [directory, name, mode] = process.argv.slice(2);
const module = new WebAssembly.Module(
    readFileSync(`${directory}/wasm-panic-message-${name}-${mode}.wasm`));
const imports = WebAssembly.Module.imports(module).map((i) => `${i.module}.${i.name}`).sort();
const expected = {
    hostless: [],
    "empty-write": [],
    "folded-write": [],
    clock: ["abla_host.clock_ns"],
    exit: ["abla_host.exit"],
    "unused-output": ["abla_host.write"],
    write: ["abla_host.write"],
}[name];
if (JSON.stringify(imports) !== JSON.stringify(expected)) {
    throw new Error(`${name} ${mode}: imports ${imports} (expected ${expected})`);
}
let written = "";
const host = {
    write(fd, data, length) {
        const bytes = new Uint8Array(memory.buffer, data, length);
        if (fd === 2) written += new TextDecoder().decode(bytes);
        return length;
    },
    exit() { throw new Error("exit"); },
    clock_ns() { return 0n; },
    random() { return 0; },
};
let memory;
const given = {};
for (const entry of imports) given[entry.split(".")[1]] = host[entry.split(".")[1]];
const { exports } = new WebAssembly.Instance(module, { abla_host: given });
memory = exports.memory;
try {
    exports.trigger();
    throw new Error("unsupported value did not trap");
} catch (caught) {
    if (!(caught instanceof WebAssembly.RuntimeError)) throw caught;
}
const line = "panic: unsupported value (runtime tag 8)\n";
const wanted = imports.includes("abla_host.write") ? line : "";
if (written !== wanted) {
    throw new Error(`${name} ${mode}: wrote ${JSON.stringify(written)}, expected ${JSON.stringify(wanted)}`);
}
console.log(`${name} ${mode}: ${imports.length === 0 ? "no imports" : imports.join(",")}${wanted ? ", panic message written" : ", no message"}`);
