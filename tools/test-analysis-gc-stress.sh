#!/usr/bin/env bash
# The editor's analysis service with the compiler's heap under GC stress (#1128). tools/test-analysis-memory.sh runs a session
# over the compiler's own source; under ABLA_GC_STRESS=1 for the whole compiler it ran out of its 600 CPU seconds inside the
# first analysis, and so does a three-module session: every safe point of the compiler's fixed work (the prelude, the standard
# library) collects a heap of 30-60 MB. So this session stresses the service's requests only (ABLA_COMPILER_GC_STRESS=analysis,
# src/gc_stress_scope.ab) and collects at every STRIDE-th safe point, over tests/cases/analysis-gc-stress: main depends on
# shapes, both on util, which the session edits.
#
# The session: a cold analysis; util opened with `twice` renamed, so its dependents' uses no longer resolve; an analysis; util
# changed back with a new body; an analysis. Each request must repeatedly collect the compiler's heap (its window's count, from
# the service's `abla-gc-stress analysis analyze` lines), the cold answer must name declarations in all three modules, the
# middle one must report the unresolved `twice` in shapes.ab, a module the edit did not touch, and the last must carry util at
# its last version with shapes.ab clean and its `twice` naming util's declaration again.
#
# Mutation check (2026-11-22, cx2's control): dropping the last live slot from the hosted boxed-array owner scan (host.ab,
# __ablaRuntimeHostTraceMarkedAllocations and the parallel trace) fails this session, and the session passes without stress.
set -euo pipefail
# The editor service answers a request that outruns ABLA_ANALYSIS_BUDGET_MS (60 s by default) with an incomplete result. These analyse the compiler's own source and run
# beside other tests, so they give it the longest budget: a loaded run would otherwise compare an incomplete answer with a complete one (#1206).
export ABLA_ANALYSIS_BUDGET_MS=${ABLA_ANALYSIS_BUDGET_MS:-600000}
compiler=${1:-build/ablac}
# The normal suite collects thousands of times per session. The release suite
# uses the denser historical schedule.
default_stride=1024
if [[ ${RUN_TESTS_FULL:-0} == 1 ]]; then default_stride=256; fi
stride=${2:-$default_stride}
min_collections=512
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
if [[ ${RUN_TESTS_FULL:-0} == 1 ]]; then
    source "$project_root/tools/suite-wall-limit.sh"
    extend_suite_wall_limit "analysis gc stress" 900 900
fi
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
out="$project_root/build/analysis-gc-stress"
rm -rf "$out"; mkdir -p "$out"
cp -R "$project_root/tests/cases/analysis-gc-stress" "$out/project"
root="$out/project"

node -e '
const fs = require("fs");
const root = process.argv[1];
const target = root + "/util.ab";
const original = fs.readFileSync(target, "utf8");
const renamed = original.replace("fun twice(", "fun doubled(");
const rewritten = original.replace("value * 2", "value + value").replace("unusedEdit = 1", "unusedEdit = 2");
if (renamed === original || rewritten === original) throw new Error("an edit did not apply");
const uri = "file://" + target;
const roots = [root + "/main.ab"];
const lines = [
    { schema: 1, id: 1, method: "initialize", params: { workspaceRoots: [root], clientName: "analysis-gc-stress", clientVersion: "1", analysisMode: "graph-v1" } },
    { schema: 1, id: 2, method: "analyze", params: { roots } },
    { schema: 1, id: 3, method: "document/open", params: { uri, version: 1, text: renamed } },
    { schema: 1, id: 4, method: "analyze", params: { roots } },
    { schema: 1, id: 5, method: "document/change", params: { uri, version: 2, text: rewritten } },
    { schema: 1, id: 6, method: "analyze", params: { roots } },
    { schema: 1, id: 7, method: "shutdown", params: {} },
];
fs.writeFileSync(process.argv[2], lines.map((line) => JSON.stringify(line)).join("\n") + "\n");
' "$root" "$out/input.jsonl"

ABLA_COMPILER_GC_STRESS="analysis:$stride" ABLA_COMPILE_EVAL=jit ABLA_MAX_MEMORY_MB=4096 ABLA_MAX_SECONDS=${ABLA_MAX_SECONDS:-500} ABLA_MAX_CPU_SECONDS=${ABLA_MAX_CPU_SECONDS:-900} \
    "$project_root/tools/run-limited.sh" "$compiler" analyze --stdio < "$out/input.jsonl" > "$out/output.jsonl" 2> "$out/error.txt" || {
    echo "analysis gc stress: the session failed" >&2
    tr -d '\0' < "$out/error.txt" | sed -n '1,20p' >&2
    exit 1
}

# One window per analyze request, with a floor on how much stress each gets.
mapfile -t windows < <(tr -d '\0' < "$out/error.txt" | awk '$1 == "abla-gc-stress" && $2 == "analysis" && $3 == "analyze" { print $5 }')
if (( ${#windows[@]} != 3 )); then
    echo "analysis gc stress: ${#windows[@]} stressed analyze windows reported, expected 3" >&2
    tr -d '\0' < "$out/error.txt" | grep -a 'abla-gc-stress' >&2 || true
    exit 1
fi
for count in "${windows[@]}"; do
    if (( count < min_collections )); then
        echo "analysis gc stress: an analyze window collected the compiler's heap $count times, expected at least $min_collections (windows: ${windows[*]})" >&2
        exit 1
    fi
done

node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").map((line) => JSON.parse(line));
const answer = (id) => {
    const line = lines.find((entry) => entry.id === id);
    if (!line || !line.result) throw new Error(`no answer to request ${id}: ${JSON.stringify(line && line.error)}`);
    return line.result;
};
const document = (result, name) => {
    const found = result.documents.find((entry) => entry.uri.endsWith("/" + name));
    if (!found) throw new Error(`${name} is missing from an answer`);
    return found;
};
const named = (found) => found.occurrences.filter((occurrence) => occurrence.declarationId).length;
const twiceUses = (found) => found.occurrences.filter((occurrence) => occurrence.name === "twice");
const cold = answer(2);
for (const name of ["main.ab", "shapes.ab", "util.ab"]) {
    const found = document(cold, name);
    if (named(found) < 3) throw new Error(`the cold analysis names ${named(found)} occurrences in ${name}`);
    if (found.diagnostics.length !== 0) throw new Error(`the cold analysis reports ${JSON.stringify(found.diagnostics)} in ${name}`);
}
const renamed = answer(4);
const shapes = document(renamed, "shapes.ab");
if (!JSON.stringify(shapes.diagnostics).includes("twice")) {
    throw new Error(`after the rename, shapes.ab reports ${JSON.stringify(shapes.diagnostics)}, not the unresolved twice`);
}
if (document(renamed, "util.ab").version !== 1) throw new Error("the second analysis does not carry util.ab at version 1");
const last = answer(6);
const util = document(last, "util.ab");
if (util.version !== 2 || !util.text.includes("value + value")) throw new Error("the last analysis does not carry util.ab at version 2");
const after = document(last, "shapes.ab");
if (after.diagnostics.length !== 0) throw new Error(`after the change back, shapes.ab reports ${JSON.stringify(after.diagnostics)}`);
const uses = twiceUses(after);
if (uses.length === 0 || !uses.every((occurrence) => (occurrence.declarationId || "").includes("/util.ab:"))) {
    throw new Error(`after the change back, twice in shapes.ab names ${JSON.stringify(uses.map((occurrence) => occurrence.declarationId))}`);
}
' "$out/output.jsonl"

echo "analysis gc stress: a cold analysis, a rename and a change of a shared module, each analysed with the compiler's heap collected at every ${stride}th safe point (${windows[*]} collections)"
