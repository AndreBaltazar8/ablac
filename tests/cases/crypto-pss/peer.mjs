// abla/crypto/rsapss against Node's (OpenSSL's) RSA-PSS, and against an EMSA-PSS written here in JavaScript: our
// random-salt signatures verify in Node; Node's (salt lengths 0, the hash's, and 7) verify here; our signature with a
// given salt is byte for byte the one JavaScript's encoding and a raw private-key operation make; and a changed
// signature, message or salt length is refused. Key sizes include 2049 bits, where the encoded message is a byte
// shorter than the signature. Usage: node peer.mjs TOOL
import { constants, createHash, createPrivateKey, createPublicKey, generateKeyPairSync, generatePrimeSync, privateEncrypt, randomBytes, sign, verify } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';

const tool = process.argv[2];
const dir = mkdtempSync(path.join(tmpdir(), 'abla-pss-'));
const run = (...args) => {
    const r = spawnSync(tool, args.map((a) => (a === '' ? '-' : a)), { encoding: 'utf8' });
    return { status: r.status, out: (r.stdout ?? '').trim() };
};
let checked = 0;
const fail = (what) => { console.log('FAIL', what); process.exit(1); };
const hash = (bits, data) => createHash(`sha${bits}`).update(data).digest();
const mgf1 = (bits, seed, length) => {
    const parts = [];
    for (let counter = 0; parts.length * (bits / 8) < length; counter++) {
        const c = Buffer.alloc(4); c.writeUInt32BE(counter);
        parts.push(hash(bits, Buffer.concat([seed, c])));
    }
    return Buffer.concat(parts).subarray(0, length);
};
// EMSA-PSS-ENCODE, then the signature's length: leading zero bytes.
const encode = (bits, message, salt, modulusBits) => {
    const hLen = bits / 8, emBits = modulusBits - 1, emLen = Math.ceil(emBits / 8);
    const h = hash(bits, Buffer.concat([Buffer.alloc(8), hash(bits, message), salt]));
    const db = Buffer.concat([Buffer.alloc(emLen - salt.length - hLen - 2), Buffer.from([1]), salt]);
    const masked = Buffer.from(db.map((b, i) => b ^ mgf1(bits, h, emLen - hLen - 1)[i]));
    masked[0] &= 0xff >> (8 * emLen - emBits);
    return Buffer.concat([masked, h, Buffer.from([0xbc])]);
};
// A key of exactly `bits` bits (OpenSSL's generator rounds 8k+1 down to 8k), from two primes of half the length.
const bitLength = (x) => x.toString(2).length;
const inverse = (a, m) => { let [r0, r1, t0, t1] = [m, a % m, 0n, 1n]; while (r1) { const q = r0 / r1; [r0, r1] = [r1, r0 - q * r1]; [t0, t1] = [t1, t0 - q * t1]; } return ((t0 % m) + m) % m; };
const b64 = (x) => Buffer.from(x.toString(16).padStart(Math.ceil(x.toString(16).length / 2) * 2, '0'), 'hex').toString('base64url');
function exactKey(bits) {
    for (;;) {
        const p = generatePrimeSync(Math.ceil(bits / 2), { bigint: true }), q = generatePrimeSync(Math.floor(bits / 2), { bigint: true });
        const n = p * q, e = 65537n, phi = (p - 1n) * (q - 1n);
        if (p === q || bitLength(n) !== bits || phi % e === 0n) continue;
        const d = inverse(e, phi);
        const jwk = { kty: 'RSA', n: b64(n), e: b64(e), d: b64(d), p: b64(p), q: b64(q), dp: b64(d % (p - 1n)), dq: b64(d % (q - 1n)), qi: b64(inverse(q, p)) };
        const privateKey = createPrivateKey({ key: jwk, format: 'jwk' });
        return { privateKey, publicKey: createPublicKey(privateKey) };
    }
}
const pss = (key, bits, saltLength) => ({ key, padding: constants.RSA_PKCS1_PSS_PADDING, saltLength, });

for (const modulusLength of [2048, 2049, 3072]) {
    const { publicKey, privateKey } = modulusLength % 8 === 0 ? generateKeyPairSync('rsa', { modulusLength }) : exactKey(modulusLength);
    const priv = path.join(dir, `k${modulusLength}.pem`), pub = path.join(dir, `k${modulusLength}.pub.pem`);
    writeFileSync(priv, privateKey.export({ type: 'pkcs8', format: 'pem' }));
    writeFileSync(pub, publicKey.export({ type: 'spki', format: 'pem' }));
    // A modulus of 8k+1 bits has unbalanced primes, which abla/crypto/rsa's private keys don't take: it only verifies.
    const canSign = modulusLength % 8 === 0;
    for (const bits of [256, 384, 512]) {
        const hLen = bits / 8;
        for (const size of [0, 1, 55, 300]) {
            const message = randomBytes(size), hex = message.toString('hex');
            const label = `${modulusLength}/sha${bits}/${size}`;
            // Ours verifies in Node, with the hash's salt length and with 0.
            for (const saltLength of [hLen, 0, 7]) {
                if (canSign) {
                    const ours = run('sign-random', priv, String(bits), hex, String(saltLength));
                    if (ours.status !== 0) fail(`${label}: our signing refused: ${ours.out}`);
                    if (!verify(`sha${bits}`, message, pss(publicKey, bits, saltLength), Buffer.from(ours.out, 'hex'))) fail(`${label}: node refused our signature (salt ${saltLength})`);
                }
                // ... and our verifier takes Node's.
                const theirs = sign(`sha${bits}`, message, pss(privateKey, bits, saltLength));
                if (run('verify', pub, String(bits), String(saltLength), hex, theirs.toString('hex')).out !== 'yes') fail(`${label}: we refused node's signature (salt ${saltLength})`);
                // ... and refuse it with another salt length, with another message, and with a changed byte.
                if (run('verify', pub, String(bits), String(saltLength + 1), hex, theirs.toString('hex')).out !== 'no') fail(`${label}: accepted the wrong salt length`);
                if (run('verify', pub, String(bits), String(saltLength), hex + '00', theirs.toString('hex')).out !== 'no') fail(`${label}: accepted another message`);
                for (const at of [0, theirs.length >> 1, theirs.length - 1]) {
                    const bad = Buffer.from(theirs); bad[at] ^= 0x10;
                    if (run('verify', pub, String(bits), String(saltLength), hex, bad.toString('hex')).out !== 'no') fail(`${label}: accepted a changed signature byte ${at}`);
                }
                checked += 7;
            }
            if (!canSign) continue;
            // A given salt: our signature is the one JavaScript's encoding and a raw private operation make.
            const salt = randomBytes(hLen);
            const em = encode(bits, message, salt, modulusLength);
            const raw = privateEncrypt({ key: privateKey, padding: constants.RSA_NO_PADDING }, Buffer.concat([Buffer.alloc(Math.ceil(modulusLength / 8) - em.length), em]));
            const ours = run('sign', priv, String(bits), hex, salt.toString('hex'));
            if (ours.out !== raw.toString('hex')) fail(`${label}: signature with a given salt differs`);
            checked += 1;
        }
    }
}
// A key under 2048 bits and a hash that isn't offered are refused.
{
    const { privateKey } = generateKeyPairSync('rsa', { modulusLength: 1024 });
    const small = path.join(dir, 'small.pem');
    writeFileSync(small, privateKey.export({ type: 'pkcs8', format: 'pem' }));
    if (run('sign-random', small, '256', 'aa').status !== 3) fail('a 1024-bit key signed');
    if (run('sign-random', path.join(dir, 'k2048.pem'), '224', 'aa').status !== 3) fail('SHA-224 was offered');
    checked += 2;
}
console.log(`peer: ${checked} RSA-PSS checks agree with node`);
