// The module against Node's own ChaCha20-Poly1305 (OpenSSL's): random keys, nonces, associated data and every
// message length from 0 to 200 and some longer, seal and open in both directions, plus the pieces alone.
// Usage: node peer.mjs TOOL [ROUNDS]
import { createCipheriv, createDecipheriv, randomBytes } from 'node:crypto';
import { spawnSync } from 'node:child_process';

const tool = process.argv[2];
const rounds = Number(process.argv[3] ?? 1);
const run = (...args) => {
    const r = spawnSync(tool, args.map((a) => (a === '' ? '-' : a)), { encoding: 'utf8' });
    return { status: r.status, out: (r.stdout ?? "").trim() };
};
let checked = 0;
const fail = (what) => { console.log('FAIL', what); process.exit(1); };
const sizes = [...Array(201).keys(), 255, 256, 257, 1000, 4097];
for (let round = 0; round < rounds; round++) {
    for (const size of sizes) {
        const key = randomBytes(32), nonce = randomBytes(12), data = randomBytes(size), aad = randomBytes(size % 37);
        const cipher = createCipheriv('chacha20-poly1305', key, nonce, { authTagLength: 16 });
        cipher.setAAD(aad, { plaintextLength: size });
        const ct = Buffer.concat([cipher.update(data), cipher.final()]);
        const sealed = Buffer.concat([ct, cipher.getAuthTag()]).toString('hex');
        const hex = (b) => b.toString('hex');
        const seal = run('seal', hex(key), hex(nonce), hex(data), hex(aad));
        if (seal.out !== sealed) fail(`seal size ${size} key ${hex(key)} nonce ${hex(nonce)}`);
        const open = run('open', hex(key), hex(nonce), sealed, hex(aad));
        if (open.out !== hex(data)) fail(`open size ${size}`);
        const bad = Buffer.from(sealed, 'hex'); bad[bad.length - 1 - (size % 16)] ^= 0x80;
        if (run('open', hex(key), hex(nonce), hex(bad), hex(aad)).status !== 1) fail(`tampered open accepted, size ${size}`);
        // The raw stream, from a random counter: Node's chacha20 takes a 16-byte IV (counter little-endian, then nonce).
        const counter = Math.floor(Math.random() * 1000);
        const iv = Buffer.alloc(16); iv.writeUInt32LE(counter, 0); nonce.copy(iv, 4);
        const stream = createCipheriv('chacha20', key, iv);
        const xored = Buffer.concat([stream.update(data), stream.final()]).toString('hex');
        if (run('xor', hex(key), hex(nonce), String(counter), hex(data)).out !== xored) fail(`xor size ${size} counter ${counter}`);
        checked += 4;
    }
}
console.log(`peer: ${checked} checks agree with node`);
