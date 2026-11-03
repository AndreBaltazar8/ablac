import { readFileSync } from 'node:fs';
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
const abla_host = {
  write: (_fd, _data, length) => length,
  exit: code => { throw new Error(`unexpected exit ${code}`); },
  clock_ns: () => 0n,
  random: () => 0n,
};
const instance = new WebAssembly.Instance(module, { abla_host });
if (instance.exports.answer() !== 42n) throw new Error('colliding callbacks dispatched to the wrong function');
console.log('function identities: Wasm callbacks remain distinct');
