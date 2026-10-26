// Prints each case's remainder bits as native.ab does, from a module that must
// import nothing (no fmod from a C library).
import { readFileSync } from "node:fs";

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const imports = WebAssembly.Module.imports(module);
if (imports.length > 0) {
    console.error(`imports: ${JSON.stringify(imports)}`);
    process.exit(1);
}
const { exports } = new WebAssembly.Instance(module, {});
const count = Number(exports.count());
const lines = [];
for (let i = 0n; i < count; i++) lines.push(`${exports.bits(i)} ${exports.bits32(i)}`);
process.stdout.write(`${lines.join("\n")}\n`);
