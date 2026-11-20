// Compares the lines "n sha384 sha512" of the program with Node's crypto over the same pattern.
import { createHash } from 'node:crypto';
import { readFileSync } from 'node:fs';
const lines = readFileSync(process.argv[2], 'utf8').trim().split('\n');
const data = Buffer.alloc(70000);
for (let i = 0; i < data.length; i++) data[i] = (7 * i + 3) & 255;
let bad = 0;
for (const line of lines) {
  const [n, d384, d512] = line.split(' ');
  const part = data.subarray(0, Number(n));
  const e384 = createHash('sha384').update(part).digest('hex');
  const e512 = createHash('sha512').update(part).digest('hex');
  if (d384 !== e384 || d512 !== e512) { bad++; if (bad < 10) console.log(`mismatch at ${n}`); }
}
if (bad > 0) { console.log(`${bad} mismatches of ${lines.length}`); process.exit(1); }
console.log(`${lines.length} sizes agree with node`);
