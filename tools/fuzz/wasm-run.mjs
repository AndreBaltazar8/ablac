import { readFileSync } from "node:fs";
const module = new WebAssembly.Module(readFileSync(process.argv[2]));
let memory; const out = []; let code = 0;
class Exit extends Error { constructor(c) { super("exit"); this.code = c; } }
const abla_host = {
  write: (fd, data, length) => {
    const bytes = Buffer.from(new Uint8Array(memory.buffer, data, length));
    if (fd === 1) out.push(bytes); else if (fd === 2) process.stderr.write(bytes);
    return length;
  },
  exit: (c) => { throw new Exit(c); },
  clock_ns: () => 0n, random: (d, l) => l };
const { exports } = new WebAssembly.Instance(module, { abla_host });
memory = exports.memory;
try { code = Number(exports.run()); } catch (e) { if (e instanceof Exit) code = e.code; else { code = 101; process.stderr.write("TRAP " + e.message + "\n"); } }
process.stdout.write(Buffer.concat(out)); process.exitCode = code;
