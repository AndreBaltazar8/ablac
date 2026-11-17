// Makes cases.ab (timestamps, civil dates and texts as Abla literals) and node.txt (what Node's Date says about each,
// formatted the way cases.ab prints), for tools/test-date-edges.sh:  node gen.mjs <cases.ab> <node.txt>
import { writeFileSync } from "node:fs";

// Deterministic pseudo-random numbers (xorshift32).
let state = 2463534242;
const next = () => { state ^= state << 13; state >>>= 0; state ^= state >>> 17; state ^= state << 5; state >>>= 0; return state; };

const DAY = 86400000;
const times = [0, 1, -1, 999, 1000, -999, -1000, DAY - 1, DAY, -DAY, -DAY - 1, 86399999, 951782400000 /* 2000-02-29 */, 951868800000, 4107456000000 /* 2100-02-29 invalid date: 2100-03-01 */,
    -2208988800000 /* 1900-01-01 */, -2203891200000 /* 1900-03-01 */, 4102444800000 /* 2100-01-01 */, 253402300799999 /* 9999-12-31T23:59:59.999 */, 253402300800000, -62167219200000 /* 0000-01-01 */, -62167219200001, -62135596800000 /* 0001-01-01 */, -62135596800001,
    8640000000000000, -8640000000000000, 8639999999999999, 1709210096000, 1709164800000 /* 2024-02-29 */, 1583020800000 /* 2020-03-01 */, 1234567890123, 946684799999, 946684800000, 2147483647000, 2147483648000, -2147483648000, -2147483649000, 4294967295000, 4294967296000,
    7952342400000 /* 2222-02-22 */, 32503680000000 /* 3000-01-01 */, 951782399999, -1000000000000, 1000000000000, 1e15, -1e15, 1e14 + 1, -1e14 - 1];
for (let year = 1; year < 4000; year += 97) { times.push(Date.UTC(year, 1, 28, 23, 59, 59, 999)); times.push(Date.UTC(year, 2, 1)); times.push(Date.UTC(year, 11, 31, 23, 59, 59, 999)); }
for (const year of [0, 4, 100, 400, 1600, 1700, 1800, 1900, 2000, 2100, 2200, 2400, 9996, 9999]) for (const [m, d] of [[0, 1], [1, 28], [1, 29], [2, 1], [11, 31]]) { const t = new Date(0); t.setUTCFullYear(year, m, d); t.setUTCHours(0, 0, 0, 0); times.push(t.getTime()); }
for (let i = 0; i < 250; i++) times.push(Math.floor((next() / 4294967296 - 0.5) * 2 * 8.64e15 / 1000) * 1000 + (next() % 1000));
for (let i = 0; i < 250; i++) times.push((next() % 2000000000) * 1000 + (next() % 1000) - 1000000000000);
const unique = [...new Set(times.filter((t) => Math.abs(t) <= 8.64e15))];

const pad = (n, w) => String(n).padStart(w, "0");
const names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
const lines = [];
const leap = (y) => (y % 4 === 0 && y % 100 !== 0) || y % 400 === 0;
const fields = (t) => {
    const d = new Date(t);
    const y = d.getUTCFullYear();
    const mo = d.getUTCMonth() + 1;
    const lengths = [31, leap(y) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let doy = d.getUTCDate();
    for (let i = 0; i < mo - 1; i++) doy += lengths[i];
    return { y, mo, d: d.getUTCDate(), h: d.getUTCHours(), mi: d.getUTCMinutes(), s: d.getUTCSeconds(), ms: d.getUTCMilliseconds(), wd: d.getUTCDay(), doy };
};
for (const t of unique) {
    const f = fields(t);
    const inRange = f.y >= 0 && f.y <= 9999;
    const iso = inRange ? `${pad(f.y, 4)}-${pad(f.mo, 2)}-${pad(f.d, 2)}T${pad(f.h, 2)}:${pad(f.mi, 2)}:${pad(f.s, 2)}.${pad(f.ms, 3)}Z` : "-";
    const http = inRange ? `${names[f.wd]}, ${pad(f.d, 2)} ${months[f.mo - 1]} ${pad(f.y, 4)} ${pad(f.h, 2)}:${pad(f.mi, 2)}:${pad(f.s, 2)} GMT` : "-";
    lines.push(`t ${t} ${f.y} ${f.mo} ${f.d} ${f.h} ${f.mi} ${f.s} ${f.ms} ${f.wd} ${f.doy} ${iso} ${http.replace(/ /g, "_")}`);
}
// civil dates -> milliseconds, valid and invalid (invalid ones must be null from the parsers; utcMilliseconds is only for valid dates)
const dateTexts = [];
for (const y of [0, 1, 1900, 1970, 1999, 2000, 2024, 2100, 9999]) for (const m of [1, 2, 3, 4, 12]) for (const d of [0, 1, 28, 29, 30, 31, 32]) dateTexts.push([y, m, d]);
dateTexts.push([2024, 0, 1], [2024, 13, 1], [10000, 1, 1]);
const parseCases = [];
for (const [y, m, d] of dateTexts) {
    const valid = y >= 0 && y <= 9999 && m >= 1 && m <= 12 && d >= 1 && d <= new Date(Date.UTC(2000, m, 0)).getUTCDate() - (m === 2 && !((y % 4 === 0 && y % 100 !== 0) || y % 400 === 0) ? 1 : 0) + 0;
    const dim = m >= 1 && m <= 12 ? [31, ((y % 4 === 0 && y % 100 !== 0) || y % 400 === 0) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][m - 1] : 0;
    const ok = y >= 0 && y <= 9999 && m >= 1 && m <= 12 && d >= 1 && d <= dim;
    const text = `${pad(y, 4)}-${pad(m, 2)}-${pad(d, 2)}`;
    let ms = "null";
    if (ok) { const t = new Date(0); t.setUTCFullYear(y, m - 1, d); t.setUTCHours(0, 0, 0, 0); ms = String(t.getTime()); }
    parseCases.push([text, ms]);
    if (ok) {
        parseCases.push([text + "T23:59:59Z", String(Number(ms) + 86399000)]);
        parseCases.push([text + "T23:59:59.999Z", String(Number(ms) + 86399999)]);
        parseCases.push([text + "T24:00:00Z", "null"]);
        parseCases.push([text + "T00:60:00Z", "null"]);
        parseCases.push([text + "T00:00:60Z", "null"]);
    }
}
for (const bad of ["", "2024", "2024-1-1", "2024-01-1", "24-01-01", "2024/01/01", "2024-01-01T", "2024-01-01T00:00", "2024-01-01T00:00:00", "2024-01-01 00:00:00Z", "2024-01-01t00:00:00Z", "2024-01-01T00:00:00z", "2024-01-01T00:00:00+00:00", "2024-01-01T00:00:00.1Z", "2024-01-01T00:00:00.12Z", "2024-01-01T00:00:00.1234Z", "2024-01-01T00:00:00.Z", "2024-01-01T00:00:00,123Z", "2024-01-01T00:00:00Z ", " 2024-01-01", "2024-01-01\n", "2024-01-01T00:00:00ZZ", "+2024-01-01", "-0001-01-01", "2024-01-0a", "2024-0a-01", "２０２４-01-01", "2024-01-01T0a:00:00Z", "2024-01-01T00:00:00.00aZ", "20240101", "20240101T000000Z"]) parseCases.push([bad, "null"]);
const http = [];
const httpGood = [0, 951782400000, 1709164800000, 1583020800000, 253402300799000, -2208988800000, 86399000, -1000, 1234567890000];
for (const t of httpGood) { const f = fields(t); http.push([`${names[f.wd]}, ${pad(f.d, 2)} ${months[f.mo - 1]} ${pad(f.y, 4)} ${pad(f.h, 2)}:${pad(f.mi, 2)}:${pad(f.s, 2)} GMT`, String(t)]); }
for (const bad of ["Mon, 01 Jan 1970 00:00:00 GMT", "Thu, 01 Jan 1970 00:00:00 GMT ", " Thu, 01 Jan 1970 00:00:00 GMT", "Thu, 1 Jan 1970 00:00:00 GMT", "Thu, 01 jan 1970 00:00:00 GMT", "Thu, 01 Foo 1970 00:00:00 GMT", "Thu, 32 Jan 1970 00:00:00 GMT", "Thu, 01 Jan 1970 24:00:00 GMT", "Thu, 01 Jan 1970 00:00:00 UTC", "Thu, 01 Jan 1970 00:00:00 +0000", "Thu 01 Jan 1970 00:00:00 GMT", "Thursday, 01-Jan-70 00:00:00 GMT", "Thu Jan  1 00:00:00 1970", "Thu, 30 Feb 2024 00:00:00 GMT", "Thu, 29 Feb 2023 00:00:00 GMT", "", "GMT"]) http.push([bad, "null"]);

const enc = (s) => { let o = ""; for (const x of Buffer.from(s, "utf8")) o += (x >= 32 && x < 127 && x !== 34 && x !== 92 && x !== 36) ? String.fromCharCode(x) : "\\x" + x.toString(16).padStart(2, "0"); return o; };
let src = `// Generated by gen.mjs: do not edit.\nimport "abla/io"\nimport "abla/text"\nimport "abla/date"\n\nfun times(): array<int> = [\n${unique.map((t) => "    " + (t < 0 ? `-${-t}` : t) + ",").join("\n").replace(/-9223372036854775808/, "-9223372036854775807 - 1")}\n]\n\n`;
src += `fun isoTexts(): array<string> = [\n${parseCases.map(([t]) => `    "${enc(t)}",`).join("\n")}\n]\n\nfun httpTexts(): array<string> = [\n${http.map(([t]) => `    "${enc(t)}",`).join("\n")}\n]\n\n`;
src += `fun nullable(v: int?): string = if (v == null) "null" else "\${v}"
fun flat(s: string): string = s.replace(" ", "_")

fun cases(): array<string> {
    val out: array<string> = []
    for (t in times()) {
        val d = utcDate(t)
        val inRange = d.year >= 0 && d.year <= 9999
        val iso = if (inRange) d.iso8601() else "-"
        val http = if (inRange) flat(d.httpDate()) else "-"
        // the fields rebuilt into a time, and the formatted text parsed back, must give the time
        var back = if (d.milliseconds() == t) "" else " MILLISECONDS-DIFFER"
        if (inRange && utcIso8601Parse(iso) != t) back = back + " ISO-ROUNDTRIP-DIFFERS"
        if (inRange && d.millisecond == 0 && httpDateParse(d.httpDate()) != t) back = back + " HTTP-ROUNDTRIP-DIFFERS"
        out.append("t \${t} \${d.year} \${d.month} \${d.day} \${d.hour} \${d.minute} \${d.second} \${d.millisecond} \${d.weekday} \${d.dayOfYear()} \${iso} \${http}\${back}")
    }
    for (s in isoTexts()) out.append("iso \${nullable(utcIso8601Parse(s))}")
    for (s in httpTexts()) out.append("http \${nullable(httpDateParse(s))}")
    return out
}

fun main: int {
    val live = cases()
    val staged = #cases()
    var bad = 0
    if (live.size != staged.size) bad = 1
    for (i in 0 until (if (live.size < staged.size) live.size else staged.size)) {
        if (live[i] != staged[i]) {
            println("DIFF live: \${live[i]} | staged: \${staged[i]}")
            bad = bad + 1
        }
    }
    for (line in live) println(line)
    bad
}
`;
const node = lines.concat(parseCases.map(([, ms]) => "iso " + ms), http.map(([, ms]) => "http " + ms));
writeFileSync(process.argv[2], src);
writeFileSync(process.argv[3], node.join("\n") + "\n");
console.log(unique.length, parseCases.length, http.length);
