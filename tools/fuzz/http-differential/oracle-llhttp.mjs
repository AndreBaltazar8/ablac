// The reference verdicts of Node's llhttp (the HTTPParser behind node:http) for the streams of gen.mjs, one line per stream:
//   <id>\t<R:method path bodyhex> | ... | E:<llhttp error code> (refused) or I (incomplete, nothing more happened)
//   node oracle-llhttp.mjs cases.tsv > llhttp.tsv
import { readFileSync } from "node:fs";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { HTTPParser, methods } = require("_http_common");
const lines = readFileSync(process.argv[2], "latin1").split("\n").filter(Boolean);
const out = [];
// An absolute-form target is served by its path (RFC 9112 3.2.2), as Abla's servers do: the path is compared in origin form.
const originForm = (target) => { const m = /^[A-Za-z][A-Za-z0-9+.-]*:\/\/[^\/]*(.*)$/.exec(target); return m ? (m[1] || "/") : target; };
for (const line of lines) {
    const [id, , hex] = line.split("\t");
    const stream = Buffer.from(hex, "hex");
    const parser = new HTTPParser();
    parser.initialize(HTTPParser.REQUEST, {});
    const verdict = [];
    let current = null;
    parser[HTTPParser.kOnHeadersComplete] = (major, minor, headers, method, url) => { current = { method: methods[method], path: originForm(String(url).split("?")[0]), body: [] }; };
    parser[HTTPParser.kOnBody] = (b) => { current.body.push(Buffer.from(b)); };
    parser[HTTPParser.kOnMessageComplete] = () => { const body = Buffer.concat(current.body).toString("hex") || "-"; verdict.push(`R:${current.method} ${current.path} ${body}`); current = null; };
    const result = parser.execute(stream);
    if (result instanceof Error) verdict.push(`E:${result.code ?? result.message}`);
    out.push(`${id}\t${verdict.length === 0 ? "I" : verdict.join(" | ")}`);
}
console.log(out.join("\n"));
