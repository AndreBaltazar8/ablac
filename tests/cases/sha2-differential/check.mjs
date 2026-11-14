// The oracle for streams.ab (tools/test-sha2-differential.sh): Node's crypto recomputes every digest from the same generator.
import { createHash, createHmac } from 'node:crypto';
import { readFileSync } from 'node:fs';
let state = 1;
const next = () => { let x = state; x = (x ^ (x << 13)) >>> 0; x = (x ^ (x >>> 17)) >>> 0; x = (x ^ (x << 5)) >>> 0; state = x; return x; };
const below = (l) => l <= 0 ? 0 : next() % l;
const bytesOf = (n) => { const b = Buffer.alloc(n); for (let i = 0; i < n; i++) b[i] = next() & 255; return b; };
const lines = readFileSync(process.argv[2], 'utf8').trim().split('\n');
const maximum = Number(process.argv[3]);
let bad = 0;
for (const line of lines) {
  const f = line.split(' ');
  const seed = Number(f[0]);
  state = Number((BigInt(seed) * 2654435761n) % 4294967291n) + 1;
  const kind = below(4);
  const size = kind == 0 ? below(200) : kind == 1 ? below(5000) : kind == 2 ? 64 * below(100) + below(3) - 1 : below(maximum);
  const total = size < 0 ? 0 : size;
  const chunks = []; let made = 0, updates = 0;
  while (made < total) {
    const want = below(8) == 0 ? 0 : 1 + below(below(3) == 0 ? 70000 : 130);
    const take = made + want > total ? total - made : want;
    chunks.push(bytesOf(take)); made += take; updates++;
  }
  const joined = Buffer.concat(chunks);
  const pad = below(7);
  bytesOf(pad); bytesOf(3);
  const key = bytesOf(below(200));
  const h = (a, d) => createHash(a).update(d).digest('hex');
  const m = (a, k, d) => createHmac(a, k).update(d).digest('hex');
  const want = [String(seed), String(joined.length), String(updates), String(pad), String(key.length), h('sha256', joined), h('sha256', joined), h('sha256', joined),
    m('sha256', key, joined), h('sha384', joined), h('sha512', joined), m('sha384', key, joined), m('sha512', key, joined)];
  const names = ['seed', 'size', 'updates', 'pad', 'key', 'stream', 'sha256', 'sha256(slice)', 'hmac256', 'sha384', 'sha512(slice)', 'hmac384(slice)', 'hmac512'];
  for (let i = 0; i < want.length; i++) if (f[i] !== want[i]) { bad++; if (bad < 20) console.log(`MISMATCH seed ${seed} ${names[i]} size ${joined.length}: abla ${f[i]} node ${want[i]}`); }
}
console.log(`${lines.length} seeds, ${bad} mismatches`);
process.exit(bad ? 1 : 0);
