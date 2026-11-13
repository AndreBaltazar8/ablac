// Emit a file-free AArch64 numerical test with BigInt-computed answers.
// Usage: node aarch64-kat.mjs OUTPUT.ab
import fs from 'node:fs';

const gcd = (a, b) => { while (b) [a, b] = [b, a % b]; return a; };
const inverse = (value, modulus) => {
    let [r0, r1, t0, t1] = [modulus, value % modulus, 0n, 1n];
    while (r1) { const q = r0 / r1; [r0, r1] = [r1, r0 - q * r1]; [t0, t1] = [t1, t0 - q * t1]; }
    return ((t0 % modulus) + modulus) % modulus;
};
const lines = ['import "abla/crypto/bignum"', 'import "abla/ct"', ''];
const checks = [];
[1, 3, 17, 64, 128].forEach((words, testCase) => {
    const bits = BigInt(words * 32);
    let modulus = (1n << (bits - 1n)) + 1000n + BigInt(testCase);
    modulus = testCase % 2 ? modulus | 1n : (modulus >> 1n) << 1n;
    const value = 65537n;
    while (gcd(modulus, value) !== 1n) modulus += 2n;
    const expectedInverse = inverse(value, modulus);
    const numerator = modulus * 0x1234567n + 17n;
    const exact = modulus * 0x1234567n;
    const expectedQuotient = 0x1234567n;
    const name = `kat${testCase}`;
    checks.push(name);
    lines.push(`trusted fun ${name}(): bool {`, `    val w = ${words}`,
        '    val m = bnAllocate(w)', '    val v = bnAllocate(w)',
        '    val gcd = bnAllocate(w)', '    val inverse = bnAllocate(w)',
        '    val work = bnAllocate(13 * w + 9 * (w + 1))',
        '    val numerator = bnAllocate(2 * w)', '    val quotient = bnAllocate(2 * w)',
        '    val remainder = bnAllocate(w)', '    val scratch = bnAllocate(w)', '    var ok = true');
    const limbs = (integer, width) => Array.from({ length: width }, (_, i) => (integer >> BigInt(32 * i)) & 0xFFFFFFFFn);
    const write = (address, integer, width) => limbs(integer, width).forEach((limb, i) => {
        if (limb) lines.push(`    bnStore(${address} + ${4 * i}, secretU32(u32(${limb})))`);
    });
    const expect = (address, integer, width) => limbs(integer, width).forEach((limb, i) => {
        lines.push(`    if (bnLoad(${address} + ${4 * i}).declassify() != u32(${limb})) ok = false`);
    });
    write('m', modulus, words);
    write('v', value, words);
    lines.push('    if (bnSecretGcdBody(gcd, m, v, w, work).declassify() == u32(0)) ok = false');
    expect('gcd', 1n, words);
    lines.push('    if (bnSecretInverseBody(inverse, m, v, w, work).declassify() == u32(0)) ok = false');
    expect('inverse', expectedInverse, words);
    write('numerator', numerator, 2 * words);
    lines.push('    if (bnSecretDivModBody(quotient, remainder, numerator, 2*w, m, w, scratch).declassify() == u32(0)) ok = false');
    expect('quotient', expectedQuotient, 2 * words);
    expect('remainder', 17n, words);
    lines.push('    if (bnSecretExactDivBody(quotient, numerator, 2*w, m, w, remainder, scratch).declassify() != u32(0)) ok = false',
        '    bnClear(numerator, 2*w)');
    write('numerator', exact, 2 * words);
    lines.push('    if (bnSecretExactDivBody(quotient, numerator, 2*w, m, w, remainder, scratch).declassify() == u32(0)) ok = false');
    expect('quotient', expectedQuotient, 2 * words);
    lines.push('    if (bnSecretDivModBody(numerator, remainder, numerator, 2*w, m, w, scratch).declassify() != u32(0)) ok = false',
        '    bnRelease(m, w)', '    bnRelease(v, w)', '    bnRelease(gcd, w)', '    bnRelease(inverse, w)',
        '    bnRelease(work, 13*w + 9*(w+1))', '    bnRelease(numerator, 2*w)', '    bnRelease(quotient, 2*w)',
        '    bnRelease(remainder, w)', '    bnRelease(scratch, w)', '    ok', '}', '');
});
lines.push('@export("simd_checks")', 'fun aarch64Oracle(): int {');
checks.forEach((name, i) => lines.push(`    if (!${name}()) return ${i + 1}`));
lines.push('    0', '}', '');
fs.writeFileSync(process.argv[2], lines.join('\n'));
