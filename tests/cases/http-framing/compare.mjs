// Compares the verdicts of Abla's httpEventFrame loop with those of llhttp (oracle.mjs), name by name:
//   node compare.mjs <llhttp.txt> <abla.txt> <exceptions.txt>
// A verdict is the requests framed (R:method path body), then E when the stream was refused or nothing more (incomplete).
// Only the requests framed are compared: a stream one side refuses and the other leaves waiting frames nothing either way.
// llhttp's end-of-stream error for a request cut short by the harness closing the connection is "incomplete" here.
// Abla may refuse more than llhttp (it is meant to). Anything else that differs (Abla frames a request llhttp refuses, or
// frames it differently) must be listed in exceptions.txt ("name reason") and an exception that no longer differs is an error.
import { readFileSync } from "node:fs";
const parse = (f) => new Map(readFileSync(f, "latin1").split("\n").filter(Boolean).map((l) => { const i = l.indexOf("\t"); return [l.slice(0, i), l.slice(i + 1)]; }));
const normalize = (verdict) => {
    const tokens = verdict === "I" ? [] : verdict.split(" | ");
    const requests = tokens.filter((t) => t.startsWith("R:"));
    const refused = tokens.some((t) => t.startsWith("E") && t !== "E:HPE_INVALID_EOF_STATE");
    return { requests, refused };
};
const llhttp = parse(process.argv[2]), abla = parse(process.argv[3]);
const exceptions = new Map(readFileSync(process.argv[4], "utf8").split("\n").filter((l) => l && !l.startsWith("#")).map((l) => { const i = l.indexOf(" "); return [l.slice(0, i), l.slice(i + 1)]; }));
let bad = 0, stricter = 0, same = 0, excepted = 0;
for (const [name, v] of llhttp) {
    const n = normalize(v), a = normalize(abla.get(name));
    // The first n requests Abla frames must be the ones llhttp frames; Abla framing fewer is stricter, more is looser.
    const prefixEqual = a.requests.slice(0, n.requests.length).every((r, i) => r === n.requests[i]) && n.requests.slice(0, a.requests.length).every((r, i) => r === a.requests[i]);
    let kind;
    if (!prefixEqual) kind = "different framing";
    else if (a.requests.length > n.requests.length) kind = "frames more";
    else if (a.requests.length < n.requests.length) kind = "stricter";
    else kind = "same";
    if (kind === "same") same++;
    else if (kind === "stricter") stricter++;
    else if (exceptions.has(name)) excepted++;
    else { console.error(`${name}: ${kind}: llhttp ${v} | Abla ${abla.get(name)}`); bad = 1; }
}
for (const name of exceptions.keys()) {
    const v = llhttp.get(name), a = abla.get(name);
    if (v === undefined) { console.error(`exception for an unknown stream ${name}`); bad = 1; continue; }
    const n = normalize(v), b = normalize(a);
    if (JSON.stringify(n) === JSON.stringify(b)) { console.error(`${name}: listed in the exceptions but llhttp and Abla agree`); bad = 1; }
}
console.log(`${same} agree, ${stricter} Abla stricter, ${excepted} listed exceptions`);
process.exit(bad);
