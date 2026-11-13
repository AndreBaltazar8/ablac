// Markdown tables from a bench.mjs run result: size, gzip size, median run time and peak memory per program and
// version, each version's change against the first one.
//
// node report.mjs result.json [--skip FRACTION]: the medians drop the first FRACTION of each program's samples (a long
// run on a shared machine starts in a slower phase); the minimum is over all of them.
import fs from 'node:fs';

const argv = process.argv.slice(2);
const skip = argv.includes('--skip') ? Number(argv[argv.indexOf('--skip') + 1]) : 0;
const data = JSON.parse(fs.readFileSync(argv[0], 'utf8'));
const median = (values) => { const s = [...values].sort((a, b) => a - b); const m = s.length >> 1; return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2; };
const programs = Object.keys(data).sort();
const numbers = (v) => (v.match(/\d+/g) ?? []).map(Number);
const versions = Object.keys(Object.values(data)[0]).sort((a, b) => {
    const [da, db] = [!/\d/.test(a), !/\d/.test(b)];
    if (da !== db) return da ? -1 : 1;
    const [na, nb] = [numbers(a), numbers(b)];
    for (let i = 0; i < Math.max(na.length, nb.length); i++) if ((na[i] ?? -1) !== (nb[i] ?? -1)) return (na[i] ?? -1) - (nb[i] ?? -1);
    return a < b ? -1 : a > b ? 1 : 0;
});
const base = versions[0];
for (const p of programs) for (const v of versions) {
    const runs = data[p][v].runsMs;
    data[p][v].medianMs = median(runs.slice(Math.floor(runs.length * skip)));
}
const group = (n, digits = 0) => n.toLocaleString('en-US', { minimumFractionDigits: digits, maximumFractionDigits: digits });
const signed = (x, digits) => (x >= 0 ? '+' : '-') + Math.abs(x).toFixed(digits);

function table(title, key, format, delta = true) {
    console.log(`\n### ${title} (change against ${base})\n`);
    console.log('| program | ' + versions.join(' | ') + ' |');
    console.log('|---|' + '---:|'.repeat(versions.length));
    for (const p of programs) {
        const cells = versions.map((v) => {
            const [x, b] = [data[p][v][key], data[p][base][key]];
            return format(x) + (v === base || !delta ? '' : ` (${signed((x / b - 1) * 100, 1)}%)`);
        });
        console.log(`| ${p} | ` + cells.join(' | ') + ' |');
    }
    if (delta && programs.length > 1) {
        const cells = versions.map((v) => {
            let ratio = 1;
            for (const p of programs) ratio *= data[p][v][key] / data[p][base][key];
            return v === base ? '' : `${signed((ratio ** (1 / programs.length) - 1) * 100, 2)}%`;
        });
        console.log('| **geomean change** | ' + cells.join(' | ') + ' |');
    }
}

table('Module size (bytes)', 'bytes', (x) => group(x));
table('Gzip size (bytes)', 'gzipBytes', (x) => group(x));
table('Median run time (ms)' + (skip ? `, first ${Math.round(skip * 100)}% of the rounds dropped` : ''), 'medianMs', (x) => group(x));
table('Minimum run time (ms)', 'minMs', (x) => group(x));
table('Peak linear memory (bytes)', 'memoryBytes', (x) => group(x));
console.log('\n### Run-time ranges (min to max, ms)\n');
console.log('| program | ' + versions.join(' | ') + ' |');
console.log('|---|' + '---:|'.repeat(versions.length));
for (const p of programs) console.log(`| ${p} | ` + versions.map((v) => `${group(data[p][v].minMs)} to ${group(data[p][v].maxMs)}`).join(' | ') + ' |');
const bad = programs.filter((p) => new Set(versions.map((v) => data[p][v].output)).size !== 1);
console.log('\nOutputs identical across versions: ' + (bad.length === 0 ? 'yes' : 'NO for ' + bad.join(', ')));
