// Differential check of abla/math/v8 against Node 22's Math on x86-64.
//
// A seeded generator gives the same inputs in every mode and on every Node
// (it uses only +, -, *, / and bit operations): random bit patterns,
// log-uniform magnitudes, the neighbourhoods of each function's branch points
// and of the special values, huge and subnormal arguments, ±0, ±inf, NaN. Every
// result must have the reference's bits; any NaN matches any NaN, since
// JavaScript doesn't keep NaN payloads apart.
//
// The reference is Node 22 on x86-64 Linux, which runs V8's C code as written.
// Arm64 builds of Node fuse multiply-adds in it (about 0.07% of results move by
// an ulp), and macOS's scalbn truncates pow's subnormal results, so the local
// Node is not the reference everywhere. By default each function's results are
// checked against digests recorded from x86-64 Node 22 (expected.json, by
// sample count). With `--expected <dir>`, against the result files `expect`
// wrote there (on x86-64 Node 22: per-case detail); with `--live`, against this
// Node's Math.
//
//   node run.mjs wasm <module.wasm> [samples] [reference]      exports.ab, in this process
//   node run.mjs native <program> <dir> [samples] [reference]  native.ab, through files in <dir>
//   node run.mjs ct-write <program.ab> [samples]               a program of `#` results
//   node run.mjs ct-check <output> [samples] [reference]       ...and what it printed
//   node run.mjs expect <dir> [samples]                        this Node's Math results, to files
//   node run.mjs digest [samples...]                           this Node's digests, for expected.json
//
// `samples` is the number of inputs per function (default 250,000, and 2,000
// for the ct modes).
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const argv = process.argv.slice(2);
let reference = { kind: "digest" };
for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--live") {
        reference = { kind: "live" };
        argv.splice(i--, 1);
    } else if (argv[i] === "--expected") {
        reference = { kind: "files", dir: argv[i + 1] };
        argv.splice(i--, 2);
    }
}
const [mode, first, second, third] = argv;

// --- bits ---------------------------------------------------------------------

const scratch = new Float64Array(1);
const scratchWords = new Uint32Array(scratch.buffer);
const scratchBig = new BigInt64Array(scratch.buffer);

function fromWords(high, low) {
    scratchWords[1] = high >>> 0;
    scratchWords[0] = low >>> 0;
    return scratch[0];
}
// 2^k, exactly, for k in [-1074, 1023].
function pow2(k) {
    if (k >= -1022) return fromWords((k + 1023) << 20, 0);
    return 5e-324 * pow2(k + 1074);
}
// `value` moved by `steps` units in the last place along the number line.
function ulps(value, steps) {
    if (Number.isNaN(value) || steps === 0) return value;
    scratch[0] = value;
    // order the bit patterns as a signed line: -0 and +0 meet at 0
    let ordered = scratchBig[0] < 0n ? -(scratchBig[0] & 0x7fffffffffffffffn) : scratchBig[0];
    ordered += BigInt(steps);
    scratchBig[0] = ordered < 0n ? (-ordered) | -0x8000000000000000n : ordered;
    return scratch[0];
}
// log2 |x| to within 0.09, from the bits alone.
function roughLog2(x) {
    scratch[0] = x;
    const exponent = ((scratchWords[1] >>> 20) & 0x7ff) - 1023;
    scratchWords[1] = (scratchWords[1] & 0x800fffff) | 0x3ff00000;
    return exponent + (Math.abs(scratch[0]) - 1);
}

// --- the generator -------------------------------------------------------------

// xoshiro128**, seeded per function, so every mode sees the same inputs.
function generator(seed) {
    let a = seed ^ 0x9e3779b9, b = Math.imul(seed, 0x85ebca6b), c = seed ^ 0xc2b2ae35, d = 0x27d4eb2f;
    const rotl = (x, k) => (x << k) | (x >>> (32 - k));
    const next = () => {
        const result = Math.imul(rotl(Math.imul(b, 5), 7), 9) >>> 0;
        const t = b << 9;
        c ^= a; d ^= b; b ^= c; a ^= d; c ^= t; d = rotl(d, 11);
        return result;
    };
    for (let i = 0; i < 16; i++) next();
    const random = {
        u32: next,
        unit: () => next() / 4294967296,
        int: (low, high) => low + Math.floor((next() / 4294967296) * (high - low + 1)),
        pick: (list) => list[Math.floor((next() / 4294967296) * list.length)],
        bits: () => fromWords(next(), next()),
        sign: () => (next() & 1 ? -1 : 1),
        // a magnitude with a uniformly random binary exponent in [low, high]
        magnitude(low, high) {
            const exponent = random.int(low, high);
            const mantissa = fromWords((next() & 0xfffff) | 0x3ff00000, next());
            return exponent < -1022 ? mantissa * pow2(-1022) * pow2(exponent + 1022) : mantissa * pow2(exponent);
        },
        // a step count, log-uniform in size, so neighbours and far neighbours
        // both appear
        steps: () => random.sign() * Math.floor((1 + random.unit()) * pow2(random.int(0, 43))),
    };
    return random;
}

const special = [
    0, -0, Infinity, -Infinity, NaN, 5e-324, -5e-324, 2.2250738585072009e-308,
    2.2250738585072014e-308, -2.2250738585072014e-308, Number.MAX_VALUE, -Number.MAX_VALUE,
    1, -1, 0.5, -0.5, 2, -2, 3, -3, 10, Number.EPSILON, pow2(53), pow2(31), pow2(-1022),
];

// Each function's branch points: high words as the C code tests them (both
// ends of each word, both signs) and values.
function wordsAndValues(highs, values) {
    const points = [...values];
    for (const high of highs) {
        points.push(fromWords(high, 0), fromWords(high, 0xffffffff),
            -fromWords(high, 0), -fromWords(high, 0xffffffff));
    }
    return points;
}
const halfPiMultiples = [];
for (let k = -4096; k <= 4096; k++) halfPiMultiples.push(k * (Math.PI / 2));
for (let e = 13; e < 1022; e += 3) {
    halfPiMultiples.push(pow2(e) * (Math.PI / 2), pow2(e) * Math.PI / 3);
}
// The double nearest a multiple of pi/2 (Muller: 6381956970095103 · 2^797),
// where the large reduction cancels most.
halfPiMultiples.push(6381956970095103 * pow2(797), -6381956970095103 * pow2(797));
const npio2Highs = [
    0x3FF921FB, 0x400921FB, 0x4012D97C, 0x401921FB, 0x401F6A7A, 0x4022D97C,
    0x4025FDBB, 0x402921FB, 0x402C463A, 0x402F6A7A, 0x4031475C, 0x4032D97C,
    0x40346B9C, 0x4035FDBB, 0x40378FDB, 0x403921FB, 0x403AB41B, 0x403C463A,
    0x403DD85A, 0x403F6A7A, 0x40407E4C, 0x4041475C, 0x4042106C, 0x4042D97C,
    0x4043A28C, 0x40446B9C, 0x404534AC, 0x4045FDBB, 0x4046C6CB, 0x40478FDB,
    0x404858EB, 0x404921FB,
];
const trigPoints = wordsAndValues(
    [0x3FE921FB, 0x4002D97C, 0x413921FB, 0x3E400000, 0x3E300000, 0x3FD33333,
        0x3FE90000, 0x3FE59428, 0x7FF00000, ...npio2Highs],
    [...halfPiMultiples, 0.6744, 0.3, 0.78125],
);
const expPoints = wordsAndValues(
    [0x40862E42, 0x3FD62E42, 0x3FF0A2B2, 0x3E300000],
    [709.782712893384, -745.1332191019411, 1, -1, 0.5 * Math.LN2, 1.5 * Math.LN2,
        ...Array.from({ length: 2100 }, (_, i) => (i - 1076) * Math.LN2)],
);
const logPoints = wordsAndValues(
    [0x00100000, 0x3FF00000, 0x3FEFFFFF, 0x3ff6147a, 0x3ff6b851, 0x3ff95f64, 0x3fe6a09e],
    [1, Math.SQRT2, Math.SQRT1_2, Math.E, ...Array.from({ length: 2098 }, (_, i) => pow2(i - 1074))],
);
const atanPoints = wordsAndValues(
    [0x44100000, 0x3FDC0000, 0x3E400000, 0x3FF30000, 0x3FE60000, 0x40038000, 0x7FF00000],
    [0.4375, 0.6875, 1.1875, 2.4375, 1, pow2(66)],
);
const exactPoints = [
    ...Array.from({ length: 200 }, (_, i) => (i - 100) / 2),
    ...Array.from({ length: 100 }, (_, i) => pow2(i * 10 - 500)),
    pow2(52), pow2(52) + 0.5, pow2(51) + 0.5, 4503599627370497,
];

// At most half of `count` cases from `fixed`, evenly spaced through it.
function sample(fixed, count) {
    const room = count - Math.floor(count / 2);
    if (fixed.length <= room) return fixed;
    return Array.from({ length: room }, (_, i) => fixed[Math.floor((i * fixed.length) / room)]);
}

// One-argument inputs: every point and special value with its 16 nearest
// neighbours each way (sampled when they are more than half of `count`), then
// a quarter each of random bits, log-uniform magnitudes, values around the
// points (one ulp to 2^44 away) and uniform values over the main range.
function oneArgument(random, count, points, range, exponents) {
    const neighbours = [];
    for (const point of [...special, ...points]) {
        for (let step = -16; step <= 16; step++) neighbours.push(ulps(point, step));
    }
    const values = sample(neighbours, count);
    while (values.length < count) {
        const kind = random.u32() & 3;
        if (kind === 0) values.push(random.bits());
        else if (kind === 1) values.push(random.sign() * random.magnitude(exponents[0], exponents[1]));
        else if (kind === 2) values.push(ulps(random.pick(points), random.steps()));
        else values.push(range[0] + random.unit() * (range[1] - range[0]));
    }
    values.length = count;
    return values.map((x) => [x]);
}

// Pairs of the special values and points, every combination (sampled when
// they are more than half of `count`), then `fill`.
function twoArguments(random, count, points, fill) {
    const grid = [];
    const corners = [...special, ...points];
    for (const x of corners) for (const y of corners) grid.push([x, y]);
    const pairs = sample(grid, count);
    while (pairs.length < count) pairs.push(fill(random));
    pairs.length = count;
    return pairs;
}

const anyMagnitude = (random) => random.sign() * random.magnitude(-1074, 1023);

function minMaxPair(random) {
    const kind = random.u32() & 3;
    if (kind === 0) return [random.bits(), random.bits()];
    if (kind === 1) {
        const x = anyMagnitude(random);
        return [x, random.u32() & 1 ? x : ulps(x, random.steps())];
    }
    if (kind === 2) return [random.pick(special), anyMagnitude(random)];
    return [anyMagnitude(random), random.pick(special)];
}

const FUNCTIONS = {
    sqrt: { arity: 1, math: Math.sqrt, inputs: (r, n) => oneArgument(r, n, exactPoints, [-1, 1e6], [-1074, 1023]) },
    floor: { arity: 1, math: Math.floor, inputs: (r, n) => oneArgument(r, n, exactPoints, [-1e3, 1e3], [-1074, 1023]) },
    ceil: { arity: 1, math: Math.ceil, inputs: (r, n) => oneArgument(r, n, exactPoints, [-1e3, 1e3], [-1074, 1023]) },
    trunc: { arity: 1, math: Math.trunc, inputs: (r, n) => oneArgument(r, n, exactPoints, [-1e3, 1e3], [-1074, 1023]) },
    fabs: { arity: 1, math: Math.abs, inputs: (r, n) => oneArgument(r, n, exactPoints, [-1e3, 1e3], [-1074, 1023]) },
    sin: { arity: 1, math: Math.sin, inputs: (r, n) => oneArgument(r, n, trigPoints, [-20, 20], [-60, 1023]) },
    cos: { arity: 1, math: Math.cos, inputs: (r, n) => oneArgument(r, n, trigPoints, [-20, 20], [-60, 1023]) },
    tan: { arity: 1, math: Math.tan, inputs: (r, n) => oneArgument(r, n, trigPoints, [-20, 20], [-60, 1023]) },
    atan: { arity: 1, math: Math.atan, inputs: (r, n) => oneArgument(r, n, atanPoints, [-5, 5], [-60, 80]) },
    exp: { arity: 1, math: Math.exp, inputs: (r, n) => oneArgument(r, n, expPoints, [-750, 750], [-60, 11]) },
    log: { arity: 1, math: Math.log, inputs: (r, n) => oneArgument(r, n, logPoints, [0, 4], [-1074, 1023]) },
    atan2: {
        arity: 2, math: Math.atan2,
        inputs: (r, n) => twoArguments(r, n, [1, -1, 3, 1e-300, 1e300, pow2(60), pow2(-60)], (random) => {
            const kind = random.u32() & 3;
            if (kind === 0) return [random.bits(), random.bits()];
            if (kind === 1) {
                // |y / x| near 2^±60, where the quotient is skipped
                const x = anyMagnitude(random);
                return [x * pow2(random.int(-64, 64)) * random.sign(), x];
            }
            if (kind === 2) {
                // points on a circle: (1 - t^2, 2t) / (1 + t^2), every quadrant
                const t = random.unit() * 2 - 1, radius = random.magnitude(-30, 30);
                const x = (radius * (1 - t * t)) / (1 + t * t), y = (radius * 2 * t) / (1 + t * t);
                return random.u32() & 1 ? [y, x] : [x, -y];
            }
            return random.u32() & 1 ? [anyMagnitude(random), 1] : [anyMagnitude(random), anyMagnitude(random)];
        }),
    },
    pow: {
        arity: 2, math: Math.pow,
        inputs: (r, n) => twoArguments(r, n, [0.25, 4, 7, -7, 1.5, -1.5, 1e10, -1e10, pow2(31) + 1,
            pow2(53) + 2, pow2(64) + pow2(12), 1 + pow2(-20), 1 - pow2(-21)], (random) => {
            const kind = random.u32() % 7;
            if (kind === 0) return [random.bits(), random.bits()];
            if (kind === 1) {
                // results across the whole range, the overflow and underflow
                // boundaries and subnormal results included
                const x = random.magnitude(-1074, 1023), target = -1100 + random.unit() * 2150;
                const log2 = roughLog2(x);
                return [x, target / (log2 === 0 ? 1e-9 : log2)];
            }
            if (kind === 2) {
                // x near 1 and a large y: the |y| > 2^31 branch
                return [1 + random.sign() * random.magnitude(-60, -18), random.sign() * random.magnitude(29, 70)];
            }
            if (kind === 3) {
                // negative x: integer y, odd and even, and non-integers next to them
                const y = random.sign() * random.int(0, 1 << 20) * pow2(random.int(0, 40));
                return [-random.magnitude(-30, 30), random.u32() & 1 ? y : ulps(y, random.steps())];
            }
            if (kind === 4) {
                return [anyMagnitude(random), random.pick([0, -0, 0.5, -0.5, 1, -1, 2, -2, 3, Infinity,
                    -Infinity, NaN, 1e300, -1e300, pow2(31), pow2(64)])];
            }
            if (kind === 5) {
                return [random.pick([0, -0, 1, -1, Infinity, -Infinity, NaN, 5e-324, 2, 10]),
                    random.u32() & 1 ? anyMagnitude(random) : random.int(-40, 40)];
            }
            return [random.int(-1000, 1000), random.int(-60, 60)];
        }),
    },
    hypot: {
        arity: 2, math: Math.hypot,
        inputs: (r, n) => twoArguments(r, n, [1e-300, 1e300, 3, 4], (random) => {
            const kind = random.u32() & 3;
            if (kind === 0) return [random.bits(), random.bits()];
            if (kind === 1) return [anyMagnitude(random), anyMagnitude(random)];
            if (kind === 2) {
                const x = anyMagnitude(random);
                return [x, x * random.magnitude(-60, 60) * random.sign()];
            }
            return [random.sign() * random.magnitude(-30, 30), random.sign() * random.magnitude(-30, 30)];
        }),
    },
    fmin: { arity: 2, math: Math.min, inputs: (r, n) => twoArguments(r, n, [], minMaxPair) },
    fmax: { arity: 2, math: Math.max, inputs: (r, n) => twoArguments(r, n, [], minMaxPair) },
};
const names = Object.keys(FUNCTIONS);

// One function's inputs, flattened.
function inputsOf(name, count) {
    const spec = FUNCTIONS[name];
    let seed = 0x5eed;
    for (const c of name) seed = Math.imul(seed ^ c.charCodeAt(0), 0x01000193);
    const rows = spec.inputs(generator(seed), count);
    const inputs = new Float64Array(rows.length * spec.arity);
    rows.forEach((row, i) => {
        for (let k = 0; k < spec.arity; k++) inputs[i * spec.arity + k] = row[k];
    });
    return inputs;
}

// Calls `run` on each case of `inputs`, into a result array.
function each(arity, inputs, run) {
    const results = new Float64Array(inputs.length / arity);
    if (arity === 1) {
        for (let i = 0; i < results.length; i++) results[i] = run(inputs[i]);
    } else {
        for (let i = 0; i < results.length; i++) results[i] = run(inputs[2 * i], inputs[2 * i + 1]);
    }
    return results;
}

// --- references ----------------------------------------------------------------

const asBits = (array) => new BigInt64Array(array.buffer, array.byteOffset, array.length);

// Two 32-bit hashes over each result's bits, any NaN counted as one pattern.
function digest(results) {
    const words = new Uint32Array(2);
    const value = new Float64Array(words.buffer);
    let h1 = 0x811c9dc5, h2 = 0x9e3779b9;
    for (let i = 0; i < results.length; i++) {
        value[0] = results[i];
        if (Number.isNaN(results[i])) {
            words[1] = 0x7ff80000;
            words[0] = 0;
        }
        for (let k = 0; k < 2; k++) {
            h1 = Math.imul(h1 ^ words[k], 0x01000193) >>> 0;
            h2 = Math.imul((h2 + words[k]) | 0, 0x9e3779b1);
            h2 = (h2 ^ (h2 >>> 13)) >>> 0;
        }
    }
    return `${h1.toString(16).padStart(8, "0")}${h2.toString(16).padStart(8, "0")}`;
}

function describe(value) {
    scratch[0] = value;
    return `${value} (0x${BigInt.asUintN(64, scratchBig[0]).toString(16).padStart(16, "0")})`;
}

let recorded = null;
let failures = 0;
let referenceLabel = "";

// Checks one function's results against the reference; returns mismatches.
function check(label, name, count, inputs, actual) {
    const arity = FUNCTIONS[name].arity;
    let expected = null;
    if (reference.kind === "live") {
        expected = each(arity, inputs, FUNCTIONS[name].math);
        referenceLabel = `Node ${process.versions.node} ${process.arch} Math`;
    } else if (reference.kind === "files") {
        const bytes = readFileSync(join(reference.dir, `${name}-${count}.bin`));
        expected = new Float64Array(bytes.buffer, bytes.byteOffset, bytes.length / 8);
        referenceLabel = `the results in ${reference.dir}`;
    } else {
        recorded ??= JSON.parse(readFileSync(join(here, "expected.json"), "utf8"));
        const digests = recorded.digests[String(count)];
        if (!digests) throw new Error(`expected.json records no digests for ${count} samples`);
        referenceLabel = `${recorded.reference} (recorded digests)`;
        // The generator must give the inputs the digests were recorded for.
        if (digest(inputs) !== recorded.inputs[String(count)][name]) {
            throw new Error(`${name}: this Node generated other inputs than the recorded ones`);
        }
        if (digest(actual) === digests[name]) return 0;
        console.error(`${label} ${name}: results differ from ${referenceLabel}; ` +
            `for detail, run with --expected <dir> after \`node run.mjs expect <dir> ${count}\` on x86-64 Node 22`);
        failures++;
        return 1;
    }
    if (expected.length !== actual.length) throw new Error(`${name}: ${actual.length} results for ${expected.length} cases`);
    const expectedBits = asBits(expected), actualBits = asBits(actual);
    let mismatches = 0;
    for (let i = 0; i < expected.length; i++) {
        const expectedNaN = Number.isNaN(expected[i]), actualNaN = Number.isNaN(actual[i]);
        if (expectedNaN ? actualNaN : !actualNaN && expectedBits[i] === actualBits[i]) continue;
        if (mismatches < 8) {
            const args = Array.from(inputs.subarray(i * arity, (i + 1) * arity), describe);
            console.error(`${label} ${name}(${args.join(", ")}) = ${describe(actual[i])}, reference ${describe(expected[i])}`);
        }
        mismatches++;
    }
    failures += mismatches;
    return mismatches;
}

function report(label, totals) {
    const total = Object.values(totals).reduce((a, b) => a + b, 0);
    if (failures > 0) {
        console.error(`math-v8 ${label}: ${failures} mismatches in ${total} cases`);
        process.exit(1);
    }
    const counts = new Set(Object.values(totals));
    console.log(`math-v8 ${label}: ${total} cases (${counts.size === 1 ? [...counts][0] : "varied"} per function, ` +
        `${names.length} functions) bit-identical to ${referenceLabel}`);
}

function samples(text, fallback) {
    const value = Number(text ?? fallback);
    if (!Number.isInteger(value) || value <= 0) throw new Error(`bad sample count ${text}`);
    return value;
}

// Result lines (bits as decimal, or `nan`) as an f64 array.
function parseResults(lines, start, count) {
    const results = new Float64Array(count);
    const bits = asBits(results);
    for (let i = 0; i < count; i++) {
        const line = lines[start + i];
        if (line === "nan") results[i] = NaN;
        else bits[i] = BigInt(line);
    }
    return results;
}

// --- modes -----------------------------------------------------------------------

if (mode === "wasm") {
    const count = samples(second, 250000);
    const { instance } = await WebAssembly.instantiate(readFileSync(first), {});
    const totals = {};
    for (const name of names) {
        const inputs = inputsOf(name, count);
        const actual = each(FUNCTIONS[name].arity, inputs, instance.exports[name]);
        check(first, name, count, inputs, actual);
        totals[name] = actual.length;
    }
    report(`wasm ${first}`, totals);
} else if (mode === "native") {
    const count = samples(third, 250000);
    mkdirSync(second, { recursive: true });
    const totals = {};
    for (const name of names) {
        const arity = FUNCTIONS[name].arity;
        const inputs = inputsOf(name, count);
        const bits = asBits(inputs);
        const lines = [];
        for (let i = 0; i < count; i++) lines.push(arity === 1 ? `${bits[i]}` : `${bits[2 * i]} ${bits[2 * i + 1]}`);
        const inputPath = join(second, `${name}.in`);
        writeFileSync(inputPath, lines.join("\n") + "\n");
        const run = spawnSync(first, [name, inputPath], { maxBuffer: 1 << 30, encoding: "latin1" });
        if (run.status !== 0) throw new Error(`${first} ${name} exited ${run.status}: ${run.stderr}`);
        const output = run.stdout.split("\n");
        if (output.length !== count + 1) throw new Error(`${first} ${name}: ${output.length - 1} results for ${count} inputs`);
        check(first, name, count, inputs, parseResults(output, 0, count));
        totals[name] = count;
    }
    report(`native ${first}`, totals);
} else if (mode === "ct-write") {
    // One `#` site per 500 cases keeps each evaluation under the step limit.
    const count = samples(second, 2000);
    const sites = [];
    const blocks = [];
    for (const name of names) {
        const arity = FUNCTIONS[name].arity;
        const bits = asBits(inputsOf(name, count));
        for (let start = 0; start < bits.length; start += 500 * arity) {
            const slice = Array.from(bits.subarray(start, start + 500 * arity), String);
            const site = `R${sites.length}`;
            sites.push(site);
            blocks.push(`val ${site} = #evaluate("${name}", ${arity}, [${slice.join(", ")}])`);
        }
    }
    writeFileSync(first, `// Generated by tests/cases/math-v8/run.mjs: abla/math/v8 evaluated under \`#\`;
// the program prints the results, which run.mjs checks as it does the native
// and Wasm builds'.
import "abla/io"
import "abla/float"
import "abla/math/v8"

// A NaN result (any payload) as one pattern, so the output can't depend on it.
val NOT_A_NUMBER = 0x7FF8000000000000

compile fun evaluate(function: string, arity: int, inputs: array<int>): array<int> {
    val results: array<int> = []
    var i = 0
    while (i < inputs.size) {
        val x = f64FromBits(inputs[i])
        val y = if (arity == 2) f64FromBits(inputs[i + 1]) else 0.0
        val result = when (function) {
            "sqrt" -> sqrt(x)
            "floor" -> floor(x)
            "ceil" -> ceil(x)
            "trunc" -> trunc(x)
            "fabs" -> fabs(x)
            "sin" -> sin(x)
            "cos" -> cos(x)
            "tan" -> tan(x)
            "atan" -> atan(x)
            "exp" -> exp(x)
            "log" -> log(x)
            "atan2" -> atan2(x, y)
            "pow" -> pow(x, y)
            "hypot" -> hypot(x, y)
            "fmin" -> fmin(x, y)
            "fmax" -> fmax(x, y)
            else -> 0.0 / 0.0
        }
        results.append(if (isNaN(result)) NOT_A_NUMBER else f64ToBits(result))
        i += arity
    }
    results
}

${blocks.join("\n")}

fun printAll(var out: BufferedTextWriter, results: array<int>): void {
    for (bits in results) out.writeLine(if (bits == NOT_A_NUMBER) "nan" else "\${bits}")
}

fun main: int {
    val out = bufferedStandardOutput(1 << 16)
${sites.map((s) => `    printAll(out, ${s})`).join("\n")}
    if (out.flush()) 0 else 1
}
`);
    console.log(`math-v8 ct-write: ${sites.length} compile-time sites, ${count} inputs per function`);
} else if (mode === "ct-check") {
    const count = samples(second, 2000);
    const output = readFileSync(first, "latin1").split("\n");
    if (output.length !== count * names.length + 1) {
        throw new Error(`${first}: ${output.length - 1} results for ${count * names.length} inputs`);
    }
    const totals = {};
    names.forEach((name, index) => {
        check(`# ${first}`, name, count, inputsOf(name, count), parseResults(output, index * count, count));
        totals[name] = count;
    });
    report(`compile time (${first})`, totals);
} else if (mode === "expect") {
    const count = samples(second, 250000);
    mkdirSync(first, { recursive: true });
    for (const name of names) {
        const results = each(FUNCTIONS[name].arity, inputsOf(name, count), FUNCTIONS[name].math);
        writeFileSync(join(first, `${name}-${count}.bin`), results);
    }
    console.log(`math-v8 expect: Node ${process.versions.node} ${process.arch} results for ${count} cases per function in ${first}`);
} else if (mode === "digest") {
    const out = { reference: `Node ${process.versions.node} ${process.platform}-${process.arch} Math`, inputs: {}, digests: {} };
    for (const text of argv.slice(1)) {
        const count = samples(text);
        out.inputs[String(count)] = {};
        out.digests[String(count)] = {};
        for (const name of names) {
            const inputs = inputsOf(name, count);
            out.inputs[String(count)][name] = digest(inputs);
            out.digests[String(count)][name] = digest(each(FUNCTIONS[name].arity, inputs, FUNCTIONS[name].math));
        }
    }
    console.log(JSON.stringify(out, null, 4));
} else {
    console.error("usage: node run.mjs wasm|native|ct-write|ct-check|expect|digest ...");
    process.exit(2);
}
