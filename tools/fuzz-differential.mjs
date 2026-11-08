import { readFileSync } from "node:fs";
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
let memory; let out = ""; let code = 0;
class Exit extends Error { constructor(c) { super("exit"); this.code = c; } }
const dec = new TextDecoder();
const abla_host = {
  write: (fd, data, length) => { if (fd === 1) out += dec.decode(new Uint8Array(memory.buffer, data, length)); return length; },
  exit: (c) => { throw new Exit(c); },
  clock_ns: () => 0n, random: (d, l) => l };
const { exports } = new WebAssembly.Instance(module, { abla_host });
memory = exports.memory;
try { code = Number(exports.run()); } catch (e) { if (e instanceof Exit) code = e.code; else { code = 101; out += "TRAP " + e.message; } }
process.stdout.write(out); process.exitCode = code;
