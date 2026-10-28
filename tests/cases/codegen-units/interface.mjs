// Prints a WebAssembly module's imports and exports, one a line, sorted.
import { readFileSync } from "node:fs";

const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const lines = [
    ...WebAssembly.Module.imports(module).map(entry => `import ${entry.module}.${entry.name} ${entry.kind}`),
    ...WebAssembly.Module.exports(module).map(entry => `export ${entry.name} ${entry.kind}`),
];
console.log(lines.sort().join("\n"));
