// Decimal strings at the edge of a correctly rounded parse (#1139 area 4, round 4): the exact decimal midpoint between two neighbouring
// doubles (or floats), padded and tailed so the first digit that decides the rounding falls at significant digit 767 through 803 (the
// parser keeps 800 and a flag for anything nonzero after them), with a tie (nothing nonzero after the midpoint), a tail just above it, and a
// value just below it (the midpoint minus one unit of its last digit, then nines). Each string comes with its exactly rounded double bits,
// from a BigInt computation that does not use a parser, checked against JavaScript's Number (correctly rounded for any length).
//   node f64-boundary.mjs bits [seed [count]]   the cases as "<text>\t<bits of the double>", one per line
//   node f64-boundary.mjs libc [seed [count]]    "d 0 <hex of text>" (strtod) and "f 0 <hex of text>" (strtof) lines for tests/cases/libc-parse, for double and for float midpoints
//   node f64-boundary.mjs self                   the oracle against Number on its own cases (exits 1 on a difference)
const [mode = "bits", seedText = "1", countText = "60"] = process.argv.slice(2);
let seed = Number(seedText) >>> 0 || 1;
const random = () => { seed ^= seed << 13; seed >>>= 0; seed ^= seed >>> 17; seed ^= seed << 5; seed >>>= 0; return seed / 4294967296; };
const view = new DataView(new ArrayBuffer(8));
const bitsOf = (x) => { view.setFloat64(0, x); return view.getBigUint64(0); };
const fromBits = (b) => { view.setBigUint64(0, b); return view.getFloat64(0); };
const floatBitsOf = (x) => { view.setFloat32(0, x); return view.getUint32(0); };

// A double's bits as m * 2^e with integer m.
function parts(bits) {
    const exponent = Number((bits >> 52n) & 2047n), fraction = bits & ((1n << 52n) - 1n);
    return exponent === 0 ? { m: fraction, e: -1074 } : { m: fraction | (1n << 52n), e: exponent - 1075 };
}
// A float's bits as m * 2^e.
function parts32(bits) {
    const exponent = Number((bits >> 23n) & 255n), fraction = bits & ((1n << 23n) - 1n);
    return exponent === 0 ? { m: fraction, e: -149 } : { m: fraction | (1n << 23n), e: exponent - 150 };
}
// The decimal midpoint between the double with these bits and the next one up: digits (no leading zero), and the power of ten of the last digit.
function midpoint({ m, e }) {
    // (2m + 1) * 2^(e - 1)
    const odd = 2n * m + 1n;
    let digits, last;
    if (e - 1 >= 0) { digits = (odd << BigInt(e - 1)).toString(); last = 0; } else { digits = (odd * 5n ** BigInt(1 - e)).toString(); last = e - 1; }
    // Trailing zeros are not significant (an integer midpoint of large magnitude).
    let trimmed = digits.length;
    while (trimmed > 1 && digits[trimmed - 1] === "0") trimmed -= 1;
    return { digits: digits.slice(0, trimmed), last: last + (digits.length - trimmed) };
}
// The text of digits * 10^last, plain or scientific.
function render(digits, last, scientific) {
    if (scientific) return `${digits[0]}${digits.length > 1 ? "." + digits.slice(1) : ""}e${last + digits.length - 1}`;
    if (last >= 0) return digits + "0".repeat(last);
    const fraction = -last;
    if (digits.length > fraction) return digits.slice(0, digits.length - fraction) + "." + digits.slice(digits.length - fraction);
    return "0." + "0".repeat(fraction - digits.length) + digits;
}
// The exactly rounded double of digits * 10^last: a BigInt computation, round half to even.
function exactBits(digits, last) {
    let n = BigInt(digits), d = 1n;
    if (last >= 0) n *= 10n ** BigInt(last); else d = 10n ** BigInt(-last);
    if (n === 0n) return 0n;
    // Find e with 2^52 <= n / (d * 2^e) < 2^53, or the subnormal floor e = -1074.
    const bits = (x) => x.toString(2).length;
    let e = bits(n) - bits(d) - 53;
    const scaled = (e) => e >= 0 ? [n, d << BigInt(e)] : [n << BigInt(-e), d];
    for (;;) {
        const [a, b] = scaled(e);
        const q = a / b;
        if (q >= 1n << 53n) e += 1; else if (q < 1n << 52n && e > -1074) e -= 1; else break;
    }
    if (e < -1074) e = -1074;
    const [a, b] = scaled(e);
    let q = a / b;
    const twice = 2n * (a % b);
    if (twice > b || (twice === b && (q & 1n) === 1n)) q += 1n;
    if (q === 1n << 53n) { q >>= 1n; e += 1; }
    if (e > 971) return 0x7ff0000000000000n;
    if (q < 1n << 52n) return q;
    return (BigInt(e + 1075) << 52n) | (q - (1n << 52n));
}

// The cases of one double: its midpoint to its next neighbour, in the forms described above.
function casesFor(bits, widths, part = parts) {
    const { digits, last } = midpoint(part(bits));
    const n = digits.length;
    const out = [];
    const emit = (d, l) => { out.push(render(d, l, false)); out.push(render(d, l, true)); };
    emit(digits, last);                                               // the tie itself
    for (const p of widths) {
        if (p > n) {
            emit(digits + "0".repeat(p - n), last - (p - n));         // the tie, written with trailing zeros to p digits
            emit(digits + "0".repeat(p - n - 1) + "1", last - (p - n)); // a one at digit p: above the midpoint
            const below = (BigInt(digits) - 1n).toString();
            if (below.length === n) emit(below + "9".repeat(p - n), last - (p - n)); // below it, nines out to digit p
        }
    }
    return out;
}

const specials = [0x0000000000000001n, 0x0000000000000002n, 0x000fffffffffffffn, 0x0010000000000000n, 0x3ff0000000000000n, 0x3ff0000000000001n,
    0x4340000000000000n, 0x7fefffffffffffffn, 0x7fe0000000000001n, 0x0008000000000000n, 0x3fe0000000000000n, 0x0000000000100000n];
const widths = [767, 768, 769, 790, 798, 799, 800, 801, 802, 803, 810];
function allCases(count) {
    const doubles = specials.slice();
    while (doubles.length < count) {
        // Random finite doubles, favouring the subnormal and low-exponent ranges (the longest midpoints).
        const exponent = BigInt(Math.floor(random() * (random() < 0.5 ? 40 : 2046)));
        doubles.push((exponent << 52n) | (BigInt(Math.floor(random() * 2 ** 32)) << 20n) | BigInt(Math.floor(random() * 2 ** 20)));
    }
    return doubles.flatMap((b) => casesFor(b, widths));
}

// The same for floats (strtof): midpoints between neighbouring floats, which have up to 112 significant digits.
const specials32 = [0x00000001n, 0x00000002n, 0x007fffffn, 0x00800000n, 0x3f800000n, 0x3f800001n, 0x4b800000n, 0x7f7fffffn, 0x7f000001n, 0x00400000n];
const widths32 = [100, 105, 108, 110, 111, 112, 113, 114, 115, 120, 150, 799, 800, 801, 802];
function allCases32(count) {
    const floats = specials32.slice();
    while (floats.length < count) floats.push((BigInt(Math.floor(random() * (random() < 0.5 ? 20 : 254))) << 23n) | BigInt(Math.floor(random() * 2 ** 23)));
    return floats.flatMap((b) => casesFor(b, widths32, parts32));
}

if (mode === "bits") {
    for (const text of allCases(Number(countText))) console.log(`${text}\t${exactBits(...splitText(text)).toString()}`);
} else if (mode === "libc") {
    const hex = (text) => Buffer.from(text).toString("hex");
    for (const text of allCases(Number(countText))) { console.log(`d 0 ${hex(text)}`); console.log(`f 0 ${hex(text)}`); }
    for (const text of allCases32(Number(countText))) { console.log(`f 0 ${hex(text)}`); console.log(`d 0 ${hex(text)}`); }
} else if (mode === "self") {
    let bad = 0, total = 0;
    for (const text of allCases(Number(countText))) {
        total++;
        const [digits, last] = splitText(text);
        const exact = exactBits(digits, last), js = bitsOf(Number(text));
        if (exact !== js) { bad++; if (bad < 5) console.log(`oracle disagrees with Number on ${text.slice(0, 60)}...: ${exact} ${js}`); }
    }
    console.log(`f64 boundary oracle: ${total} cases, ${bad} differences from Number`);
    process.exit(bad === 0 ? 0 : 1);
}
// digits and the power of ten of the last digit of a plain or scientific text of this file's cases.
function splitText(text) {
    let mantissa = text, exponent = 0;
    const e = text.indexOf("e");
    if (e >= 0) { mantissa = text.slice(0, e); exponent = Number(text.slice(e + 1)); }
    const dot = mantissa.indexOf(".");
    let digits = mantissa.replace(".", "");
    const fraction = dot >= 0 ? mantissa.length - dot - 1 : 0;
    digits = digits.replace(/^0+/, "") || "0";
    return [digits, exponent - fraction];
}
