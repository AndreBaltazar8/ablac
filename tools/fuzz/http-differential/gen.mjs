// Generates seeded HTTP/1.1 request streams for the framing differential (#1139 area 4): each line of the output is
//   <id>\t<tags>\t<hex of the stream>
// A stream is one request built from a grammar of framing variants (Content-Length and Transfer-Encoding spellings, lists, folds, line
// endings, chunk sizes, extensions, trailers) followed by a marker request, so that a parser that ends the first request in another
// place than the reference frames a different second request. The tags name the variants used, to group findings.
//   node gen.mjs <seed> <count> > cases.tsv
let state = Number(process.argv[2] ?? 1) >>> 0;
const count = Number(process.argv[3] ?? 1000);
const random = () => { state = (state + 0x6d2b79f5) >>> 0; let t = state; t = Math.imul(t ^ (t >>> 15), t | 1); t ^= t + Math.imul(t ^ (t >>> 7), t | 61); return ((t ^ (t >>> 14)) >>> 0) / 4294967296; };
const below = (n) => Math.floor(random() * n);
const pick = (a) => a[below(a.length)];
const chance = (p) => random() < p;
const CRLF = "\r\n";

const tags = new Set();
const tag = (t) => { tags.add(t); };

const lineEnd = () => { const r = random(); if (r < 0.93) return CRLF; tag("eol"); return pick(["\n", "\r", "\r\r\n", "\n\r\n"]); };

function contentLengthHeader(n) {
    const name = chance(0.85) ? pick(["Content-Length", "content-length", "Content-length", "CONTENT-LENGTH"]) : pick([" Content-Length", "Content-Length ", "Content-Length\t", "Content_Length", "Content-Length  "]);
    if (name !== "Content-Length" && !/^[Cc][Oo][Nn][Tt][Ee][Nn][Tt]-[Ll][Ee][Nn][Gg][Tt][Hh]$/.test(name)) tag("cl-name");
    const forms = [() => `${n}`, () => ` ${n}`, () => `${n} `, () => `\t${n}`, () => `+${n}`, () => `0${n}`, () => `${n},${n}`, () => `${n}, ${n + 1}`, () => `${n} ${n}`, () => `-${n}`, () => `0x${n.toString(16)}`, () => `${n}.0`, () => `${n}\x00`, () => `${n + 1}`, () => `${n - 1}`, () => `${n}e0`, () => "", () => "9".repeat(30), () => `${n} `];
    const weights = [60, 5, 5, 3, 3, 3, 3, 3, 2, 2, 2, 1, 1, 2, 2, 1, 1, 1, 1];
    let total = weights.reduce((a, b) => a + b, 0), x = random() * total, i = 0;
    while (x >= weights[i]) { x -= weights[i]; i++; }
    if (i !== 0) tag(`cl-value-${i}`);
    return `${name}: ${forms[i]()}`;
}

function transferEncodingHeader() {
    const name = chance(0.85) ? pick(["Transfer-Encoding", "transfer-encoding", "Transfer-encoding", "TRANSFER-ENCODING"]) : pick([" Transfer-Encoding", "Transfer-Encoding ", "Transfer-Encoding\t", "Transfer_Encoding", "Transfer-Encoding  ", "X-Transfer-Encoding"]);
    if (!/^transfer-encoding$/i.test(name)) tag("te-name");
    const values = ["chunked", "Chunked", "CHUNKED", " chunked", "chunked ", "\tchunked", "chunked\t", "chunked, identity", "identity, chunked", "chunked,chunked", "gzip, chunked", "chunked, gzip", "chunked;q=1", "xchunked", "chunke", "chunked\x00", "identity", "", ",chunked", "chunked,", "\"chunked\"", "chunked\r\n x", "chunked\r\n\tchunked", "chunked "];
    const weights = [60, 4, 4, 3, 3, 2, 2, 3, 3, 2, 3, 3, 2, 2, 2, 1, 3, 1, 2, 2, 1, 2, 2, 1];
    let total = weights.reduce((a, b) => a + b, 0), x = random() * total, i = 0;
    while (x >= weights[i]) { x -= weights[i]; i++; }
    if (i !== 0) tag(`te-value-${i}`);
    return `${name}: ${values[i]}`;
}

function extraHeaders() {
    const out = [];
    if (chance(0.3)) out.push(pick(["X-A: b", "Connection: keep-alive", "Connection: close", "Expect: 100-continue", "Upgrade: websocket", "Accept: */*", "X-A:b", "X-A : b", "X-A\t: b", "X-é: b", "X A: b", "X-B: a\r\n b", "X-B: a\r\n\tb", "Host: y", "Trailer: X-T", "TE: trailers", "Content-Type: text/plain"]));
    return out;
}

function chunkedBody(markerInside) {
    let body = "";
    const chunks = 1 + below(3);
    for (let i = 0; i < chunks; i++) {
        const data = markerInside && i === 0 ? "A".repeat(2) : "x".repeat(1 + below(8));
        let size = data.length.toString(16);
        const r = random();
        if (r < 0.80) { /* plain */ }
        else if (r < 0.84) { size = size.toUpperCase(); tag("ch-upper"); }
        else if (r < 0.88) { size = "0" + size; tag("ch-zero-pad"); }
        else if (r < 0.90) { size = " " + size; tag("ch-size-space-lead"); }
        else if (r < 0.92) { size = size + " "; tag("ch-size-space-trail"); }
        else if (r < 0.93) { size = "+" + size; tag("ch-size-plus"); }
        else if (r < 0.94) { size = "0x" + size; tag("ch-size-0x"); }
        else if (r < 0.96) { size = (data.length + 1).toString(16); tag("ch-size-wrong"); }
        else if (r < 0.97) { size = "1" + "0".repeat(15) + size; tag("ch-size-huge"); }
        else { size = size + "\t"; tag("ch-size-tab"); }
        const e = random();
        let ext = "";
        if (e < 0.10) { ext = pick([";a=b", ";a", "; a=b", ";a=\"b\"", ";a=\"b c\"", ";a=\"b\\\"c\"", ";a=\"b", ";", ";a=b;c=d", ";=b", ";a b", ";a=b\x01"]); tag("ch-ext"); }
        const eol = chance(0.95) ? CRLF : pick(["\n", "\r", "\r\r\n"]);
        if (eol !== CRLF) tag("ch-eol");
        const after = chance(0.96) ? CRLF : pick(["\n", "", " \r\n", "\r\n\r\n", "\r"]);
        if (after !== CRLF) tag("ch-data-end");
        body += size + ext + eol + data + after;
    }
    const t = random();
    let last;
    if (t < 0.80) last = "0" + CRLF + CRLF;
    else if (t < 0.86) { last = "0" + CRLF + "X-T: v" + CRLF + CRLF; tag("trailer"); }
    else if (t < 0.88) { last = "0" + CRLF + "X-T: v" + CRLF + "Content-Length: 5" + CRLF + CRLF; tag("trailer-cl"); }
    else if (t < 0.90) { last = "0\n\n"; tag("ch-last-lf"); }
    else if (t < 0.92) { last = "0" + CRLF; tag("ch-last-no-end"); }
    else if (t < 0.94) { last = "00" + CRLF + CRLF; tag("ch-last-00"); }
    else if (t < 0.96) { last = "0;x=1" + CRLF + CRLF; tag("ch-last-ext"); }
    else if (t < 0.98) { last = "0" + CRLF + "X T: v" + CRLF + CRLF; tag("trailer-bad"); }
    else { last = "0 " + CRLF + CRLF; tag("ch-last-space"); }
    return body + last;
}

const MARKER = `GET /smuggled HTTP/1.1${CRLF}Host: x${CRLF}${CRLF}`;

function makeRequest() {
    tags.clear();
    const method = chance(0.7) ? "POST" : pick(["GET", "PUT", "DELETE", "OPTIONS", "HEAD", "PATCH"]);
    const target = chance(0.8) ? "/p" : pick(["/", "/a?b=c", "*", "http://h/p", "/a%2f..", "//x"]);
    const version = chance(0.93) ? "HTTP/1.1" : "HTTP/1.0";
    if (version === "HTTP/1.0") tag("http10");
    const mode = pick(["cl", "cl", "chunked", "chunked", "both", "both2", "none", "twocl", "twote"]);
    tag(`mode-${mode}`);
    const bodyText = "hello".slice(0, 1 + below(5));
    const markerInBody = chance(0.35);
    let headers = [`Host: x`], body = "";
    const addCl = (n) => headers.push(contentLengthHeader(n));
    if (mode === "cl") { const inner = markerInBody ? MARKER : bodyText; addCl(inner.length); body = inner; if (markerInBody) tag("marker-in-body"); }
    else if (mode === "chunked") { headers.push(transferEncodingHeader()); body = chunkedBody(false); if (markerInBody) { body = body + ""; } }
    else if (mode === "both" || mode === "both2") {
        const cb = chunkedBody(false);
        const clHeader = () => addCl(markerInBody ? cb.length - 5 : cb.length);
        if (mode === "both") { clHeader(); headers.push(transferEncodingHeader()); } else { headers.push(transferEncodingHeader()); clHeader(); }
        body = cb + (markerInBody ? MARKER : "");
        if (markerInBody) tag("marker-after-chunked");
    }
    else if (mode === "twocl") { addCl(bodyText.length); addCl(chance(0.5) ? bodyText.length : bodyText.length + 3); body = bodyText; }
    else if (mode === "twote") { headers.push(transferEncodingHeader()); headers.push(transferEncodingHeader()); body = chunkedBody(false); }
    else if (chance(0.3)) { body = bodyText; tag("body-without-framing"); }
    for (const h of extraHeaders()) headers.push(h);
    if (chance(0.15)) { const i = below(headers.length + 1); headers.splice(i, 0, headers.splice(below(headers.length), 1)[0] ?? "X: y"); tag("reorder"); }
    let head = `${method} ${target} ${version}${lineEnd()}`;
    for (const h of headers) head += h + lineEnd();
    head += chance(0.96) ? CRLF : pick(["\n", "\r\n \r\n"]);
    if (head.endsWith("\r\n \r\n") || (head.endsWith("\n") && !head.endsWith(CRLF))) tag("head-end");
    return head + body + MARKER;
}


// A byte-level mutation of a valid stream: a control character, space, colon or comma replaces, or is inserted at, a random place of
// the head (before the marker request), where the framing decisions are.
function mutate(stream) {
    const headEnd = stream.indexOf(CRLF + CRLF) + 4;
    const limit = Math.max(1, headEnd > 3 ? headEnd : stream.length);
    const bytes = Buffer.from(stream, "latin1");
    let out = [...bytes];
    const edits = 1 + below(3);
    for (let i = 0; i < edits; i++) {
        const at = below(Math.min(out.length, limit + 20));
        const b = pick([13, 10, 32, 9, 0, 58, 44, 59, 128, 255, 11, 12, 34, 92, 48, 49, 45, 43]);
        const r = random();
        if (r < 0.5) out[at] = b;
        else if (r < 0.8) out.splice(at, 0, b);
        else out.splice(at, 1);
    }
    return Buffer.from(out).toString("latin1");
}
for (let i = 0; i < count; i++) {
    let stream = makeRequest();
    if (chance(0.3)) { stream = mutate(stream); tags.add("mut"); }
    console.log(`${i}\t${[...tags].sort().join(",")}\t${Buffer.from(stream, "latin1").toString("hex")}`);
}
