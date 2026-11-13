// Fixed-seed independent arithmetic oracle for the secret bignum primitives: BigInt computes what each mode must give.
// Usage: node oracle.mjs ORACLE_BINARY DIRECTORY
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

const [binary, directory] = process.argv.slice(2);
// A fixed-seed stream (splitmix64): the cases are the same on every run.
let state = 0xBEEFDA7An;
const next = () => {
    state = BigInt.asUintN(64, state + 0x9E3779B97F4A7C15n);
    let z = state;
    z = BigInt.asUintN(64, (z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n);
    z = BigInt.asUintN(64, (z ^ (z >> 27n)) * 0x94D049BB133111EBn);
    return z ^ (z >> 31n);
};
const bitsOf = (k) => { let v = 0n, got = 0; while (got < k) { v = (v << 64n) | next(); got += 64; } return v & ((1n << BigInt(k)) - 1n); };
const gcd = (a, b) => { while (b) [a, b] = [b, a % b]; return a; };
const inverse = (value, modulus) => { // pow(value, -1, modulus)
    if (modulus === 1n) return 0n;
    let [r0, r1, t0, t1] = [modulus, value % modulus, 0n, 1n];
    while (r1) { const q = r0 / r1; [r0, r1] = [r1, r0 - q * r1]; [t0, t1] = [t1, t0 - q * t1]; }
    return ((t0 % modulus) + modulus) % modulus;
};
const counts = [[32, 200], [64, 120], [128, 60], [256, 24], [512, 8], [1024, 4], [2048, 2], [4096, 1]];

function run(mode, cases) {
    const file = path.join(directory, mode + '.input');
    const wide = mode.endsWith('wide');
    fs.writeFileSync(file, cases.map(([bits, m, n]) => `${m.toString(16).padStart(bits / 4, '0')} ${n.toString(16).padStart((bits / 4) * (wide ? 2 : 1), '0')}\n`).join(''));
    const result = spawnSync(binary, [file, mode], { encoding: 'utf8', timeout: 180000, maxBuffer: 1 << 30 });
    assert.equal(result.status, 0, `${mode}: ${result.status} ${result.stderr}`);
    const lines = result.stdout.split('\n').filter((line) => line !== '');
    assert.equal(lines.length, cases.length, `${mode} ${lines.length} ${cases.length}`);
    cases.forEach(([bits, m, n], index) => {
        const [remText, quotientText, maskText] = lines[index].split(' ');
        const rem = BigInt('0x' + remText), quotient = BigInt('0x' + quotientText), mask = Number(maskText);
        assert.ok(mask === 0 || mask === 0xFFFFFFFF, `${mode} ${index} bad mask ${mask}`);
        let ok;
        if (mode === 'gcd') {
            ok = mask === 0xFFFFFFFF && rem === gcd(m, n);
        } else if (mode === 'divsteps') {
            const g = gcd(m, n);
            ok = rem === g && Boolean(mask) === (g === 1n);
            if (mask) ok &&= quotient === inverse(n, m);
        } else if (mode === 'inverse') {
            const valid = m !== 0n && gcd(m, n) === 1n;
            ok = Boolean(mask) === valid && (!valid || quotient === inverse(n, m));
        } else if (mode === 'exactwide') {
            const valid = m !== 0n && n % m === 0n;
            ok = Boolean(mask) === valid && (!valid || quotient === n / m);
        } else {
            ok = Boolean(mask) === (m !== 0n);
            if (m !== 0n) {
                ok &&= rem === n % m;
                if (mode.startsWith('division')) ok &&= quotient === n / m;
            }
        }
        assert.ok(ok, `${mode} ${index} ${bits} 0x${m.toString(16)} 0x${n.toString(16)} ${lines[index]}`);
    });
    console.log(`ok   ${mode}: ${cases.length} cases`);
}

const cases = [], wide = [], odd = [];
for (const [bits, count] of counts) {
    const limit = 1n << BigInt(bits);
    const edges = [[0n, 0n], [0n, 1n], [1n, 0n], [1n, 1n], [2n, 1n], [2n, 2n], [limit - 1n, limit - 1n], [limit - 2n, limit - 1n], [1n << BigInt(bits - 1), 1n << BigInt(bits - 2)]];
    const small = bits === 32 ? Array.from({ length: 16 }, (_, a) => Array.from({ length: 16 }, (_, b) => [BigInt(a), BigInt(b)])).flat() : [];
    const pairs = [...edges, ...small, ...Array.from({ length: count }, () => [bitsOf(bits), bitsOf(bits)])];
    for (const [a, b] of pairs) {
        cases.push([bits, a, b]);
        if (a & 1n) odd.push([bits, a, b]);
    }
    for (const [a, b] of pairs) {
        wide.push([bits, a, (b << BigInt(bits)) | bitsOf(bits)]);
        if (a) wide.push([bits, a, a * b]); // Exact, including zero quotient and full-width products.
    }
}
// Dense limb-width coverage, including all small widths and 17/64/127/128 boundaries.
for (const words of [...Array.from({ length: 8 }, (_, i) => i + 1), 12, 16, 17, 20, 24, 28, 32, 40, 48, 56, 64, 72, 80, 88, 96, 104, 112, 120, 127, 128]) {
    const bits = words * 32;
    const a = bitsOf(bits), b = bitsOf(bits);
    cases.push([bits, a, b]);
    odd.push([bits, a | 1n, b]);
    wide.push([bits, a, (b << BigInt(bits)) | bitsOf(bits)]);
    if (a) wide.push([bits, a, a * b]);
}
for (const [mode, data] of [['divsteps', odd], ['gcd', cases], ['inverse', cases], ['division', cases], ['divisionwide', wide], ['reducewide', wide], ['exactwide', wide]]) run(mode, data);
