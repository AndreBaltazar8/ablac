// Compares the verdicts of Abla's framing with a reference's, stream by stream, and groups the disagreements:
//   node compare.mjs cases.tsv reference.tsv abla.tsv [--show N]
// Per stream: same (the same requests framed), stricter (Abla frames only a prefix of the reference's requests: it refuses or waits
// where the reference goes on), looser (Abla frames requests the reference does not frame: it refused or waited), different (the first
// request ends in another place or reads another body: the smuggling case). Only looser and different are findings; they are grouped by
// kind and the reference's error, with the generator tags that occur most in the group and the shortest stream as the example.
// Extra requests whose method is not one llhttp registers are not counted: Abla takes any token as a method (RFC 9110 9.1).
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
const { methods } = createRequire(import.meta.url)("_http_common");
const known = new Set(methods);
const rows = (f) => new Map(readFileSync(f, "latin1").split("\n").filter(Boolean).map((l) => { const i = l.indexOf("\t"); return [l.slice(0, i), l.slice(i + 1)]; }));
const cases = new Map(readFileSync(process.argv[2], "latin1").split("\n").filter(Boolean).map((l) => { const [id, tags, hex] = l.split("\t"); return [id, { tags, hex }]; }));
const reference = rows(process.argv[3]), abla = rows(process.argv[4]);
const show = Number(process.argv[process.argv.indexOf("--show") + 1] || 10);

// With --known, a "looser" stream is explained when it falls in one of the differences Abla keeps on purpose (tests/cases/http-framing/exceptions.txt
// has the reasons): identical duplicate Content-Length values, tab around chunked in Transfer-Encoding, whitespace after the semicolon of a
// chunk extension, a method that is any token (llhttp knows registered ones), a request target passed on as received (bytes above 127).
// Findings are the unexplained ones and every "different".
const known_rules = [
    (refusal, tags) => refusal === "E:HPE_UNEXPECTED_CONTENT_LENGTH" && tags.includes("mode-twocl"),
    (refusal, tags, stream) => refusal === "E:HPE_INVALID_TRANSFER_ENCODING" && /chunked[ ]*\t|\t[ ]*chunked/.test(stream),
    (refusal, tags) => refusal === "E:HPE_STRICT" && tags.includes("ch-ext"),
    (refusal, tags) => (refusal === "E:HPE_INVALID_METHOD" || refusal === "E:HPE_INVALID_URL") && tags.includes("mut"),
];
const parts = (v) => (v === "I" ? [] : v.split(" | "));
const requests = (v) => parts(v).filter((t) => t.startsWith("R:"));
const refusal = (v) => parts(v).find((t) => t.startsWith("E") && t !== "E:HPE_INVALID_EOF_STATE" && t !== "E:HPE_CLOSED_CONNECTION") ?? "none";
const useKnown = process.argv.includes("--known");
const counts = { same: 0, stricter: 0, looser: 0, different: 0, token: 0, explained: 0 };
const groups = new Map();
for (const [id, v] of reference) {
    const a = abla.get(id);
    if (a === undefined) { console.error(`no Abla verdict for ${id}`); process.exit(2); }
    const r = requests(v), b = requests(a);
    const common = Math.min(r.length, b.length);
    let kind;
    if (!r.slice(0, common).every((x, i) => x === b[i])) kind = "different";
    else if (b.length > r.length) kind = !known.has(b[r.length].slice(2).split(" ")[0]) ? "token" : "looser";
    else if (b.length < r.length) kind = "stricter";
    else kind = "same";
    if (kind === "looser" && useKnown && known_rules.some((rule) => rule(refusal(v), cases.get(id).tags, Buffer.from(cases.get(id).hex, "hex").toString("latin1")))) kind = "explained";
    counts[kind]++;
    if (kind === "looser" || kind === "different") {
        const key = `${kind} reference=${refusal(v)}`;
        if (!groups.has(key)) groups.set(key, []);
        groups.get(key).push(id);
    }
}
console.log(`${cases.size} streams: ${counts.same} same, ${counts.stricter} Abla stricter, ${counts.token} Abla frames a request with an unregistered method llhttp refuses, ${counts.explained} looser by design, ${counts.looser} Abla looser, ${counts.different} different`);
const sorted = [...groups].sort((x, y) => (x[0].startsWith("different") ? 0 : 1) - (y[0].startsWith("different") ? 0 : 1) || y[1].length - x[1].length);
for (const [key, ids] of sorted.slice(0, show)) {
    const tagCounts = new Map();
    for (const id of ids) for (const t of cases.get(id).tags.split(",").filter(Boolean)) tagCounts.set(t, (tagCounts.get(t) ?? 0) + 1);
    const top = [...tagCounts].sort((x, y) => y[1] - x[1]).slice(0, 8).map(([t, n]) => `${t}:${n}`).join(" ");
    const id = ids.reduce((best, c) => (cases.get(c).hex.length < cases.get(best).hex.length ? c : best), ids[0]);
    console.log(`\n${key} (${ids.length} streams) tags ${top}\n  shortest ${id}: ${JSON.stringify(Buffer.from(cases.get(id).hex, "hex").toString("latin1"))}\n  reference: ${reference.get(id)}\n  Abla:      ${abla.get(id)}`);
}
process.exit(counts.different > 0 || counts.looser > 0 ? 1 : 0);
