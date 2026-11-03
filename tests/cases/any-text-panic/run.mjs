import { readFileSync } from "node:fs";
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
if (WebAssembly.Module.imports(module).length !== 0) {
    throw new Error("hostless module gained imports");
}
const { exports } = new WebAssembly.Instance(module, {});
try {
    exports.trigger();
    throw new Error("unsupported value did not trap");
} catch (caught) {
    if (!(caught instanceof WebAssembly.RuntimeError)) throw caught;
}
console.log("hostless Wasm unsupported value traps without imports");
