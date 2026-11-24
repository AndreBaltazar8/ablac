import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const compiler = resolve(process.argv[2]);
const root = mkdtempSync(join(tmpdir(), "abla-analysis-scale."));

function measure(count, budget) {
    const directory = join(root, String(count));
    mkdirSync(directory, { recursive: true });
    const imports = [];
    for (let i = 0; i < count; ++i) {
        const module = `part${String(i).padStart(4, "0")}.ab`;
        writeFileSync(join(directory, module), `fun value${i}(): int = ${i}\n`);
        imports.push(`import "${module}"\n`);
    }
    const entry = join(directory, "main.ab");
    writeFileSync(entry, imports.join("") + "fun main: int = value0()\n");
    const requests = [
        ["initialize", { workspaceRoots: [directory], analysisMode: "graph-v2" }],
        ["analyze", { roots: [entry], fields: ["diagnostics"] }],
        ["analyze", { fields: ["diagnostics"], since: "1" }],
        ["shutdown", {}],
    ];
    if (budget === undefined) requests.splice(2, 1);
    const result = spawnSync("time", ["-p", compiler, "analyze", "--stdio"], {
        input: requests.map(([method, params], index) =>
            JSON.stringify({ schema: 1, id: index + 1, method, params })).join("\n") + "\n",
        encoding: "utf8",
        maxBuffer: 32 * 1024 * 1024,
        timeout: 120000,
        env: { ...process.env, LC_ALL: "C",
            ...(budget === undefined ? {} : { ABLA_ANALYSIS_BUDGET_MS: String(budget) }) },
    });
    assert.ifError(result.error);
    assert.equal(result.status, 0, result.stderr);
    const replies = result.stdout.trimEnd().split("\n").map(JSON.parse);
    assert.deepEqual(replies.map((reply) => reply.id), requests.map((_, index) => index + 1), result.stderr);
    assert.equal(replies.at(-1).result, null, "service did not finish the shutdown request");
    const seconds = [...result.stderr.matchAll(/^(?:user|sys) ([0-9.]+)$/gm)].map((match) => Number(match[1]));
    assert.equal(seconds.length, 2, result.stderr);
    return { cpu: seconds[0] + seconds[1], replies: replies.slice(1, -1).map((reply) => reply.result) };
}

try {
    const small = measure(1000);
    const large = measure(2000);
    for (const [count, run] of [[1000, small], [2000, large]]) {
        const [snapshot] = run.replies;
        assert.equal(snapshot.complete, true, JSON.stringify(snapshot.issues));
        assert.equal(snapshot.documents.filter((document) => /\/part\d+\.ab$/.test(document.uri)).length, count);
    }
    const ratio = large.cpu / small.cpu;
    const timing = `${small.cpu.toFixed(2)}s → ${large.cpu.toFixed(2)}s CPU (${ratio.toFixed(2)}×)`;
    assert.ok(ratio <= 2.8, `doubling modules took ${timing}`);
    const { replies: incomplete } = measure(32, 1);
    for (const snapshot of incomplete) {
        assert.equal(snapshot.complete, false);
        assert.deepEqual(snapshot.documents, []);
        assert.match(snapshot.issues[0].message, /request time budget exceeded/);
    }
    assert.equal(incomplete[1].full, true);
    console.log(`analysis scaling: ${timing}; deadline replies remain incomplete`);
} finally {
    rmSync(root, { recursive: true, force: true });
}
