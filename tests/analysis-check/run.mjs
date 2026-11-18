// A randomised edit loop under ABLA_ANALYSIS_CHECK=1 (incremental analysis against a cold one, after every edit; see
// bootstrapAnalysisCheckEnabled in src/analysis_graph.ab). Usage: node run.mjs <runner> <compiler> <project root> <entry> <seed> <edits>.
// The edits are of the kinds an editing session has: a line inside a function body, a comment, a new function, a new generic, an
// overload of an existing function, an import line added or removed, a declaration removed, an invalid line, and a module put back to
// what it was. Each is applied to a random module on top of what the service holds for it. The check fails the run on any difference
// between the answer after the edit and the answer of a cold analysis of the same text.
import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import readline from "node:readline";

const [runner, compiler, root, entry, seedText, editsText] = process.argv.slice(2);
let state = Number(seedText) >>> 0 || 1;
const random = () => {
    state ^= state << 13; state >>>= 0;
    state ^= state >>> 17;
    state ^= state << 5; state >>>= 0;
    return state / 4294967296;
};
const pick = (items) => items[Math.floor(random() * items.length)];

const sources = fs.readdirSync(path.join(root, path.dirname(entry)))
    .filter((name) => name.endsWith(".ab"))
    .map((name) => path.join(root, path.dirname(entry), name));
const original = new Map(sources.map((file) => [file, fs.readFileSync(file, "utf8")]));
const current = new Map(original);
const main = path.join(root, entry);

const lines = [];
let id = 0;
const send = (method, params) => lines.push({ schema: 1, id: ++id, method, params });
send("initialize", { workspaceRoots: [root], clientName: "analysis-check", clientVersion: "1", analysisMode: "graph-v2" });
send("analyze", { roots: [main] });
const versions = new Map();
const kinds = [];
const operations = {
    body(text) {
        const heads = [...text.matchAll(/^(?:private |inline )*fun [^\n]*\{\n/gm)];
        if (heads.length === 0) return null;
        const head = pick(heads);
        const at = head.index + head[0].length;
        return text.slice(0, at) + `    val checkEdit${id} = ${id}\n` + text.slice(at);
    },
    comment(text) { return text + `\n// a comment ${id}\n`; },
    addFunction(text) { return text + `\nfun checkAdded${id}(value: int): int = value + ${id}\n`; },
    addGeneric(text) { return text + `\nfun <T> checkGeneric${id}(value: T): T = value\n`; },
    overload(text) {
        const functions = [...text.matchAll(/^fun ([a-zA-Z0-9_]+)\(([^)]*)\): int = /gm)];
        if (functions.length === 0) return null;
        const chosen = pick(functions);
        return text + `\nfun ${chosen[1]}(checkOverload${id}: string): int = ${id}\n`;
    },
    importLine(text) {
        const imports = [...text.matchAll(/^import "[^"]+"\n/gm)];
        if (imports.length > 0 && random() < 0.5) {
            const gone = pick(imports);
            return text.slice(0, gone.index) + text.slice(gone.index + gone[0].length);
        }
        return `import "abla/text"\n` + text;
    },
    removeDeclaration(text) {
        const declarations = [...text.matchAll(/^fun [^\n]*\n(?:(?:    |\}| )[^\n]*\n)*/gm)];
        if (declarations.length === 0) return null;
        const gone = pick(declarations);
        return text.slice(0, gone.index) + text.slice(gone.index + gone[0].length);
    },
    invalid(text) { return text + `\nfun checkInvalid${id}( {\n`; },
    revert(text, file) { return original.get(file); },
};
const names = Object.keys(operations);
const edits = Number(editsText);
for (let edit = 0; edit < edits; edit += 1) {
    const file = pick(sources);
    const kind = pick(names);
    const next = operations[kind](current.get(file), file);
    if (next === null || next === current.get(file)) continue;
    current.set(file, next);
    const uri = "file://" + file;
    const version = (versions.get(file) ?? 0) + 1;
    versions.set(file, version);
    send(version === 1 ? "document/open" : "document/change", { uri, version, text: next });
    send("analyze", { roots: [main] });
    kinds.push(`${kind}:${path.basename(file)}`);
}
send("shutdown", {});

const analyses = 1 + kinds.length;
const selfTest = Boolean(process.env.ANALYSIS_CHECK_SELFTEST);
// ANALYSIS_CHECK_SINCE=1: also the since comparison (it parses the whole answer twice for every analysis, so the suite asks it of a small program
// and the full form of the compiler's own source).
const compareSince = Boolean(process.env.ANALYSIS_CHECK_SINCE);
const child = spawn(runner, [compiler, "analyze", "--stdio"], {
    stdio: ["pipe", "pipe", "pipe"],
    env: { ...process.env, ABLA_ANALYSIS_CHECK: selfTest ? "2" : "1", ABLA_SYSROOT: process.env.ABLA_SYSROOT ?? root },
});
let stderr = "";
child.stderr.on("data", (chunk) => { stderr += chunk; });
const exited = new Promise((resolve) => child.on("close", (code) => resolve(code)));
const reader = readline.createInterface({ input: child.stdout })[Symbol.asyncIterator]();
const exchange = async (request) => {
    child.stdin.write(JSON.stringify(request) + "\n");
    const next = await reader.next();
    if (next.done) throw new Error("the service closed its output");
    return JSON.parse(next.value);
};

// After every analysis the same revision is asked again with `since` the one before: what it carries must be what the full answer says
// of those documents, what it calls unchanged must be what the previous full answer said, and nothing else may be left out.
const problems = [];
let held = null;
let carriedTotal = 0;
let unchangedTotal = 0;
for (const request of lines) {
    if (request.method === "shutdown") continue;
    if (request.method !== "analyze") { await exchange(request); continue; }
    const full = await exchange(request);
    const result = full.result;
    if (!result || !Array.isArray(result.documents)) { problems.push(`an analyze answer without documents: ${JSON.stringify(full).slice(0, 200)}`); continue; }
    if (!compareSince) continue;
    const docs = new Map(result.documents.map((document) => [document.uri, JSON.stringify(document)]));
    if (compareSince && !selfTest && held !== null && result.complete !== undefined) {
        const delta = await exchange({ ...request, id: request.id + 1000000, params: { ...request.params, since: held.revision } });
        const cut = delta.result;
        if (!cut) problems.push(`the since request failed: ${JSON.stringify(delta.error)}`);
        else if (cut.full === false) {
            const carried = new Map(cut.documents.map((document) => [document.uri, JSON.stringify(document)]));
            for (const [uri, text] of carried) if (docs.get(uri) !== text) problems.push(`carried ${uri} differs from the full answer`);
            const unchanged = new Set(cut.unchanged);
            for (const uri of unchanged) {
                if (carried.has(uri)) problems.push(`${uri} is carried and unchanged`);
                if (!docs.has(uri) || held.docs.get(uri) !== docs.get(uri)) problems.push(`unchanged ${uri} differs from the previous answer`);
            }
            for (const uri of docs.keys()) if (!carried.has(uri) && !unchanged.has(uri)) problems.push(`${uri} is neither carried nor unchanged`);
            const removed = new Set(cut.removed);
            for (const uri of held.docs.keys()) if (!docs.has(uri) && !removed.has(uri)) problems.push(`${uri} is gone but not listed as removed`);
            carriedTotal += carried.size;
            unchangedTotal += unchanged.size;
        } else {
            for (const document of cut.documents) if (docs.get(document.uri) !== JSON.stringify(document)) problems.push(`full since answer: ${document.uri} differs`);
            if (cut.documents.length !== docs.size) problems.push("a full since answer with another number of documents");
        }
    }
    held = { revision: result.revision, docs };
}
await exchange({ schema: 1, id: 2000000, method: "shutdown", params: {} });
child.stdin.end();
const status = await exited;
const log = stderr.split("\n").filter((line) => line.startsWith("abla-analysis-check"));
const different = log.filter((line) => line.includes("DIFFERENT") || line.includes("FAILED"));
const ok = log.filter((line) => line.includes(" ok "));
console.log(`analysis-check: seed ${seedText}, ${analyses} analyses, edits ${kinds.join(" ")}`);
if (selfTest) {
    // The check's own test: every analysis was made to differ, and each must be reported.
    if (different.length === 0 || ok.length !== 0) {
        console.error(`analysis-check self-test: a difference was not reported (${ok.length} ok, ${different.length} reported)`);
        process.exit(1);
    }
    console.log(`analysis-check self-test: a difference is reported`);
    process.exit(0);
}
if (status !== 0 && ok.length < analyses) {
    console.error(`analysis-check: the service exited ${status} after ${ok.length} checked analyses`);
    console.error(stderr.split("\n").slice(0, 20).join("\n"));
    process.exit(1);
}
if (different.length > 0 || ok.length !== analyses || problems.length > 0) {
    console.error(`analysis-check: ${ok.length} of ${analyses} analyses agree with a cold analysis, ${problems.length} problems with the since answers`);
    for (const line of different.slice(0, 30)) console.error(line);
    for (const line of problems.slice(0, 30)) console.error(line);
    process.exit(1);
}
console.log(`analysis-check: all ${analyses} analyses agree with a cold analysis${compareSince ? `; the since answers carried ${carriedTotal} and left out ${unchangedTotal} documents, all as the full answers say` : ""}`);
