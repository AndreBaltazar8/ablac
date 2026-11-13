// Cases for abla/uint256, int256, uint128 and int128, worked out with JavaScript's BigInt (an oracle independent of
// Abla's): edge values against each other, then random ones of every length. tests/cases/wide-integers/checks*.ab run
// them on each target.
//
// gen-cases.mjs SEED COUNT [--type T]            lines of `operation a b expected`, in hex unless noted
// gen-cases.mjs SEED COUNT [--type T] --abla     the same as an Abla module holding them in WIDE_CASES
// gen-cases.mjs SEED COUNT [--type T] --decimal-abla  compile-time decimal formatting against BigInt's text
//
// A value is shown as its two's complement in BITS bits (`ff..ff` is -1 for a signed type); a signed
// type's decimal and hex text carry a minus.
import { pathToFileURL } from 'node:url';

export function model(type) {
    const SIGNED = type.startsWith('int');
    const BITS = Number(type.slice(-3));
    const BYTES = BITS / 8;
    const M = 1n << BigInt(BITS);
    const TOP = M - 1n;
    const [LOW, HIGH] = SIGNED ? [-(M >> 1n), (M >> 1n) - 1n] : [0n, TOP];
    const abs = (v) => (v < 0n ? -v : v);
    const mod = (v, m) => ((v % m) + m) % m;
    const wrap = (v) => { v = mod(v, M); return SIGNED && v > HIGH ? v - M : v; };
    const hexed = (v) => mod(v, M).toString(16);
    const fits = (v) => LOW <= v && v <= HIGH;
    const checked = (v) => (fits(v) ? hexed(v) : 'n');
    const narrowed = (v, low, high) => (low <= v && v <= high ? hexed(v) : 'n');
    // Truncating, the way an Abla signed type does; the one quotient too large wraps.
    const divide = (a, b) => { const q = abs(a) / abs(b); return wrap((a < 0n) !== (b < 0n) ? -q : q); };
    const remainder = (a, b) => (!(SIGNED && a === LOW && b === -1n) ? a - divide(a, b) * b : 0n);
    const textHex = (v) => (v < 0n ? `-0x${(-v).toString(16)}` : `0x${v.toString(16)}`);
    const bitLength = (v) => (v === 0n ? 0 : abs(v).toString(2).length);
    const bytesOf = (v, length, little, signed) => {
        const hex = mod(v, 1n << BigInt(8 * length)).toString(16).padStart(2 * length, '0');
        const bytes = hex.match(/../g) ?? [];
        return (little ? bytes.reverse() : bytes).join('');
    };
    const pow = (b, e) => BigInt(b) ** BigInt(e);
    const base = [0n, 1n, 2n, 3n, 5n, 9n, 10n, 255n, 256n, TOP, TOP - 1n, TOP / 2n, TOP / 2n + 1n, TOP / 10n, TOP / 10n + 1n,
        pow(10, 9), pow(10, 18), pow(10, 19), pow(10, 38), 1n << BigInt(BITS / 2), (1n << BigInt(BITS / 2)) - 1n,
        (1n << BigInt(BITS / 2)) + 1n, 0xFFFFFFFFn, 0xFFFFFFFFn << BigInt(BITS - 32), BigInt('0x' + 'AA'.repeat(BYTES)),
        BigInt('0x' + '55'.repeat(BYTES)), BigInt('0x' + '0123456789abcdef'.repeat(BITS / 64)), pow(2, 63) - 1n, pow(2, 63),
        pow(2, 64) - 1n, pow(2, 64), pow(2, 32), pow(2, 16), pow(2, 8), pow(2, 31), pow(2, 31) - 1n, pow(2, 15), pow(2, 15) - 1n,
        pow(2, 7), pow(2, 7) - 1n, (M >> 1n) - 1n, M >> 1n, (M >> 1n) + 1n];
    for (let k = 32; k < BITS; k += 32) { base.push(1n << BigInt(k)); base.push((1n << BigInt(k)) - 1n); }
    if (BITS === 256) base.push(pow(10, 77));
    const edgeSet = new Map();
    for (const v of base) { edgeSet.set(wrap(v), 1); if (SIGNED) edgeSet.set(wrap(-v), 1); }
    const EDGES = [...edgeSet.keys()].sort((x, y) => (x < y ? -1 : x > y ? 1 : 0));
    const SHIFTS = [0, 1, 4, 31, 32, 33, 63, 64, 65, 127, 128, 129, 200, 255, 256, 257, 1000];
    const BAD_DECIMAL = ['', '-', '+1', ' 1', '1 ', '1.5', '1e3', '0x10', 'a', '--1', '-+1', String(M), String(M + 5n),
        String(pow(10, 78)), '9'.repeat(100), String(HIGH + 1n), String(LOW - 1n)];
    if (!SIGNED) BAD_DECIMAL.push('-1');
    const BAD_HEX = ['', '0x', '0X', 'g', '0xg', ' 0x1', '0x 1', '0x' + '1' + '0'.repeat(BYTES * 2), 'F'.repeat(BYTES * 2 + 1),
        '-', '-0x', '0x-1', '--1', '+1', (HIGH + 1n).toString(16), `0x${(HIGH + 1n).toString(16)}`, `-0x${(-LOW + 1n).toString(16)}`];
    if (!SIGNED) BAD_HEX.push('-1');

    function* pairLines(a, b) {
        const x = hexed(a), y = hexed(b);
        yield `add ${x} ${y} ${hexed(a + b)}`;
        yield `sub ${x} ${y} ${hexed(a - b)}`;
        yield `mul ${x} ${y} ${hexed(a * b)}`;
        if (b !== 0n) {
            yield `div ${x} ${y} ${hexed(divide(a, b))}`;
            yield `rem ${x} ${y} ${hexed(remainder(a, b))}`;
        }
        yield `and ${x} ${y} ${hexed(a & b)}`;
        yield `or ${x} ${y} ${hexed(a | b)}`;
        yield `xor ${x} ${y} ${hexed(a ^ b)}`;
        yield `lt ${x} ${y} ${+(a < b)}`;
        yield `le ${x} ${y} ${+(a <= b)}`;
        yield `gt ${x} ${y} ${+(a > b)}`;
        yield `ge ${x} ${y} ${+(a >= b)}`;
        yield `eq ${x} ${y} ${+(a === b)}`;
        yield `ne ${x} ${y} ${+(a !== b)}`;
        yield `addc ${x} ${y} ${checked(a + b)}`;
        yield `subc ${x} ${y} ${checked(a - b)}`;
        yield `mulc ${x} ${y} ${checked(a * b)}`;
    }

    function* oneLines(a, rng) {
        const x = hexed(a);
        const pattern = mod(a, M);
        yield `not ${x} 0 ${hexed(~a)}`;
        yield `neg ${x} 0 ${hexed(-a)}`;
        yield `dec ${x} 0 ${a}`;
        yield `decp ${a} 0 ${x}`;
        if (a >= 0n) yield `decp ${'0'.repeat(rng.below(4))}${a} 0 ${x}`;
        else yield `decp -${'0'.repeat(rng.below(4))}${-a} 0 ${x}`;
        if (SIGNED) {
            yield `hexs ${x} 0 ${textHex(a)}`;
            yield `hexp ${textHex(a)} 0 ${x}`;
            yield `hexp ${textHex(a).toUpperCase().replace('0X', '0x')} 0 ${x}`;
            yield a < 0n ? `hexp -${(-a).toString(16)} 0 ${x}` : `hexp ${a.toString(16)} 0 ${x}`;
        } else {
            yield `hexs ${x} 0 0x${x}`;
            yield `hexp 0x${x} 0 ${x}`;
            yield `hexp ${x.toUpperCase()} 0 ${x}`;
        }
        yield `lowc ${x} 0 1`;
        yield `bytes ${x} 0 ${bytesOf(pattern, BYTES, false)}`;
        yield `bytesle ${x} 0 ${bytesOf(pattern, BYTES, true)}`;
        if (SIGNED) {
            const minimal = a === 0n ? 0 : Math.floor((bitLength(a > 0n ? a : ~a) + 1 + 7) / 8);
            const length = minimal + rng.below(BYTES + 1 - minimal);
            if (length) {
                yield `bytesp ${bytesOf(a, length, false)} 0 ${x}`;
                yield `bytesple ${bytesOf(a, length, true)} 0 ${x}`;
            }
            yield `sign ${x} 0 ${(a > 0n ? 1 : 0) - (a < 0n ? 1 : 0) + 1}`;
            yield `abs ${x} 0 ${hexed(abs(a))}`;
        } else {
            const minimal = Math.floor((bitLength(a) + 7) / 8);
            const length = a !== 0n ? minimal + rng.below(BYTES + 1 - minimal) : rng.below(BYTES + 1);
            if (length) {
                yield `bytesp ${bytesOf(a, length, false)} 0 ${x}`;
                yield `bytesple ${bytesOf(a, length, true)} 0 ${x}`;
            }
            yield `bits ${x} 0 ${bitLength(a)}`;
        }
        const index = rng.below(BITS);
        yield `bit ${x} ${index.toString(16)} ${(pattern >> BigInt(index)) & 1n}`;
        yield `u64n ${x} 0 ${narrowed(a, 0n, pow(2, 64) - 1n)}`;
        yield `intn ${x} 0 ${narrowed(a, SIGNED ? -pow(2, 63) : 0n, pow(2, 63) - 1n)}`;
        yield `u32n ${x} 0 ${narrowed(a, 0n, pow(2, 32) - 1n)}`;
        yield `u16n ${x} 0 ${narrowed(a, 0n, pow(2, 16) - 1n)}`;
        yield `u8n ${x} 0 ${narrowed(a, 0n, pow(2, 8) - 1n)}`;
        if (SIGNED) yield `i32n ${x} 0 ${narrowed(a, -pow(2, 31), pow(2, 31) - 1n)}`;
        yield `u64 ${x} 0 ${hexed(pattern & (pow(2, 64) - 1n))}`;
        yield `u32 ${x} 0 ${hexed(pattern & (pow(2, 32) - 1n))}`;
        yield `u16 ${x} 0 ${hexed(pattern & 65535n)}`;
        yield `u8 ${x} 0 ${hexed(pattern & 255n)}`;
        const low = pattern & (pow(2, 64) - 1n);
        yield `sext ${hexed(low)} 0 ${hexed(low < pow(2, 63) ? low : low - pow(2, 64))}`;
        yield `zext ${hexed(low)} 0 ${hexed(low)}`;
    }

    function* shiftLines(a, count) {
        const x = hexed(a);
        const pattern = mod(a, M);
        const c = BigInt(count);
        const inRange = count < BITS;
        yield `shl ${x} ${count.toString(16)} ${inRange ? hexed(a << c) : '0'}`;
        yield `shr ${x} ${count.toString(16)} ${inRange ? hexed(a >> c) : '0'}`;
        if (SIGNED) {
            yield `ushr ${x} ${count.toString(16)} ${inRange ? hexed(pattern >> c) : '0'}`;
        } else {
            yield `shlw ${x} ${count.toString(16)} ${inRange ? hexed(a << c) : '0'}`;
            yield `shrw ${x} ${count.toString(16)} ${inRange ? hexed(a >> c) : '0'}`;
        }
    }

    // splitmix64 over BigInt: a seeded stream is all the cases need.
    function generator(seed) {
        let state = BigInt.asUintN(64, BigInt(seed));
        const next = () => {
            state = BigInt.asUintN(64, state + 0x9E3779B97F4A7C15n);
            let z = state;
            z = BigInt.asUintN(64, (z ^ (z >> 30n)) * 0xBF58476D1CE4E5B9n);
            z = BigInt.asUintN(64, (z ^ (z >> 27n)) * 0x94D049BB133111EBn);
            return z ^ (z >> 31n);
        };
        const below = (n) => Number(next() % BigInt(n));
        const bits = (k) => { let v = 0n, got = 0; while (got < k) { v = (v << 64n) | next(); got += 64; } return v & ((1n << BigInt(k)) - 1n); };
        const sample = (list, k) => {
            const copy = list.slice();
            for (let i = 0; i < k; i++) { const j = i + below(copy.length - i); [copy[i], copy[j]] = [copy[j], copy[i]]; }
            return copy.slice(0, k);
        };
        return { below, bits, sample };
    }

    function randomValue(rng) {
        const value = wrap(rng.bits(rng.below(BITS + 1)));
        return SIGNED && rng.below(2) ? wrap(-value) : value;
    }

    function lines(seed, count) {
        const rng = generator(seed);
        const out = [];
        for (const text of BAD_DECIMAL) out.push(`decp ${text.replaceAll(' ', '_') || '_'} 0 n`);
        for (const text of BAD_HEX) out.push(`hexp ${text.replaceAll(' ', '_') || '_'} 0 n`);
        out.push('bytesp ' + '01'.repeat(BYTES + 1) + ' 0 n');
        out.push('bytesple ' + '01'.repeat(BYTES + 1) + ' 0 n');
        if (SIGNED) out.push('decp -0 0 0');
        for (const a of EDGES) {
            out.push(...oneLines(a, rng));
            for (const c of SHIFTS) out.push(...shiftLines(a, c));
        }
        for (const a of EDGES) {
            for (const b of rng.sample(EDGES, Math.min(SIGNED ? 4 : 9, EDGES.length))) out.push(...pairLines(a, b));
        }
        const cornerSet = new Map();
        for (const v of [LOW, LOW + 1n, -1n, 0n, 1n, 2n, HIGH - 1n, HIGH, TOP, TOP - 1n, M >> 1n, (M >> 1n) + 1n]) cornerSet.set(wrap(v), 1);
        const corners = [...cornerSet.keys()].sort((x, y) => (x < y ? -1 : x > y ? 1 : 0));
        for (const a of corners) for (const b of corners) out.push(...pairLines(a, b));
        while (out.length < count) {
            const a = randomValue(rng);
            const b = rng.below(4) ? randomValue(rng) : EDGES[rng.below(EDGES.length)];
            out.push(...pairLines(a, b));
            out.push(...oneLines(a, rng));
            out.push(...shiftLines(a, [...SHIFTS, rng.below(BITS)][rng.below(SHIFTS.length + 1)]));
        }
        return out;
    }

    return { BITS, SIGNED, EDGES, SHIFTS, lines, pairLines, oneLines, shiftLines, generator, randomValue, wrap, pow };
}

function main() {
    const args = process.argv.slice(2);
    const type = args.includes('--type') ? args[args.indexOf('--type') + 1] : 'uint256';
    const [seed, count] = [BigInt(args[0]), Number(args[1])];
    const m = model(type);
    if (args.slice(2).includes('--decimal-abla')) {
        const rng = m.generator(seed);
        const set = new Map();
        for (const v of m.EDGES) set.set(v, 1);
        for (let n = 0; n <= Math.floor(m.BITS * 3 / 10); n++) {
            for (const d of [-1n, 0n, 1n]) {
                set.set(m.wrap(m.pow(10, n) + d), 1);
                if (m.SIGNED) set.set(m.wrap(-(m.pow(10, n) + d)), 1);
            }
        }
        const values = [...set.keys()].sort((x, y) => (x < y ? -1 : x > y ? 1 : 0));
        for (let i = 0; i < count; i++) values.push(m.randomValue(rng));
        console.log('// Generated decimal answers from BigInt, including powers of ten and their neighbors.');
        console.log(`import "abla/${type}"`);
        console.log('val DECIMALS = "' + values.map((n) => `${n}\\n`).join('') + '"');
        console.log(`
fun decimalText(): string {
    var out = ""
    var start = 0
    for (at in 0 until DECIMALS.size) {
        if (int(DECIMALS[at]) == 10) {
            val value = ${type}FromDecimal(DECIMALS.slice(start, at))
            if (value == null) return "parse failed"
            out = "$out$value\\n"
            start = at + 1
        }
    }
    out
}
compile fun compiledDecimalText(): string = decimalText()
val compiledDecimals = #compiledDecimalText()
fun main: int {
    if (compiledDecimals != DECIMALS) return 1
    if (decimalText() != DECIMALS) return 2
    0
}
`);
        return;
    }
    const cases = m.lines(seed, count);
    if (args.slice(2).includes('--abla')) {
        console.log('// Generated by tools/wide-integers/gen-cases.mjs.');
        console.log('val WIDE_CASES = "' + cases.join('\\n') + '\\n"');
    } else {
        console.log(cases.join('\n'));
    }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) main();
