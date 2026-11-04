import { readFileSync } from 'node:fs';
for (const path of process.argv.slice(2)) {
  const module = new WebAssembly.Module(readFileSync(path));
  const imports = WebAssembly.Module.imports(module);
  if (imports.some(x => x.module !== 'abla_host')) throw new Error(JSON.stringify(imports));
  let memory;
  const host = {
    write(fd, pointer, length) {
      const text = new TextDecoder().decode(new Uint8Array(memory.buffer, pointer, length));
      throw new Error(`unexpected write: ${fd}: ${text}`);
    },
    exit(code) { throw new Error(`unexpected exit ${code}`); },
    clock_ns() { return 0n; },
    random() { throw new Error('unexpected random'); }
  };
  const { exports } = new WebAssembly.Instance(module, { abla_host: host });
  memory = exports.memory;
  for (let i = 0; i < 3; ++i) {
    if (exports.arrayMove() !== 42n) throw new Error(`arrayMove failed: ${path}`);
  }
}
console.log('array move-out: native/CT semantics preserved in release and fast Wasm');
