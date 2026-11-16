#!/usr/bin/env bash
# The editor's cost on a program of the compiler's own size (#814): `ablac analyze --stdio` in graph mode over src/orc_main.ab
# (the compiler's source, 306,000 name occurrences) peaks in resident memory under a bound. Every occurrence once held an
# identity string with the source path in it, and the occurrence index a key with the path: 2,270,000 kB (the compiler of
# before the fix, 2,249,000 on today's source); with the identities shared, no path in the index keys, and the types shared,
# about 2,060,000 (1,985,000 from the fixed path). The service's answer must also name a declaration for the occurrences it names (a sanity check that the
# run analysed something).
#
# The editor keeps the source path in its identities (they are what the client sees), so the peak follows the length of the
# checkout's path: the source is analysed from a copy at a path of fixed length, and the lowest of two runs counts (the
# runs differ by a few MB; a checkout path 25 characters longer is ~80 MB). The bound, 2,040,000, sits between the fixed compiler's level
# and the old one's.
#
# The editor then edits: the same service analyses after an edit to a module many modules depend on, after the same text again,
# and after a second edit (the loop of a client at a keystroke). Each analysis once kept the previous answer (a tree of ~2 GB)
# alive while it built the next, and the loop peaked at 3.2-3.9 GB; the previous generation is now released first, and
# the answer's occurrences are kept as text, so the loop peaks near the first analysis's level. Its bound, 2,200,000 kB (1,930,000 measured), sits
# between that and the old behaviour's; the final answer must carry the edited module at its last version.
#
# The loop's resident size is not a stable measure: the same compiler peaked at 2.03 GB alone and 2.29 GB in a loaded suite run (it is
# about twice the live heap, 0.94 GB: the rest is what the heap holds between collections, and how much depends on when the kernel and
# the collector's free helper get to run; one busy loop beside it, or eight, did not reproduce it). So the loop is bounded by what the
# service itself reports with ABLA_COMPILER_MEMORY_TRACE: the most live heap bytes it saw at its phase boundaries
# (abla-analysis-peak-live, bootstrapAnalysisSampleMemory), which the load does not change. The resident size keeps its bound too,
# as the lowest of two runs when the first is over it.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
output_directory="$project_root/build/analysis-memory"
bound_kilobytes=2040000
edit_bound_kilobytes=2200000
edit_live_bound_bytes=1030000000
mkdir -p "$output_directory"
if ! /usr/bin/env time --version >/dev/null 2>&1; then
    echo "analysis-memory: needs GNU time (shell.nix has it)" >&2
    exit 1
fi
root=$(mktemp -d /tmp/analysis-memory.XXXXXX)
trap 'rm -rf "$root"' EXIT
cp -R "$project_root/src" "$project_root/stdlib" "$project_root/runtime" "$root/"

node -e '
const fs = require("fs");
const root = process.argv[1];
const lines = [
    { schema: 1, id: 1, method: "initialize", params: { workspaceRoots: [root], clientName: "analysis-memory", clientVersion: "1", analysisMode: "graph-v1" } },
    { schema: 1, id: 2, method: "analyze", params: { roots: [root + "/src/orc_main.ab"] } },
    { schema: 1, id: 3, method: "shutdown", params: {} },
];
fs.writeFileSync(process.argv[2], lines.map((line) => JSON.stringify(line)).join("\n") + "\n");
' "$root" "$output_directory/input.jsonl"

node -e '
const fs = require("fs");
const root = process.argv[1];
const target = root + "/src/module_paths.ab";
const original = fs.readFileSync(target, "utf8");
const first = original.replace("fun bootstrapEncodeModulePrefix(modulePath: string): string {\n", "fun bootstrapEncodeModulePrefix(modulePath: string): string {\n    val unusedEdit = 1\n");
if (first === original) throw new Error("the edit did not apply");
const uri = "file://" + target;
const main = root + "/src/orc_main.ab";
const lines = [
    { schema: 1, id: 1, method: "initialize", params: { workspaceRoots: [root], clientName: "analysis-memory", clientVersion: "1", analysisMode: "graph-v1" } },
    { schema: 1, id: 2, method: "analyze", params: { roots: [main] } },
    { schema: 1, id: 3, method: "document/open", params: { uri, version: 1, text: first } },
    { schema: 1, id: 4, method: "analyze", params: { roots: [main] } },
    { schema: 1, id: 5, method: "analyze", params: { roots: [main] } },
    { schema: 1, id: 6, method: "document/change", params: { uri, version: 2, text: first.replace("unusedEdit = 1", "unusedEdit = 2") } },
    { schema: 1, id: 7, method: "analyze", params: { roots: [main] } },
    { schema: 1, id: 8, method: "shutdown", params: {} },
];
fs.writeFileSync(process.argv[2], lines.map((line) => JSON.stringify(line)).join("\n") + "\n");
' "$root" "$output_directory/edit-input.jsonl"

peak=""
for run in 1 2; do
    ABLA_SYSROOT="$root" ABLA_COMPILE_EVAL=jit ABLA_MAX_MEMORY_MB=4096 ABLA_MAX_SECONDS=1800 ABLA_MAX_CPU_SECONDS=600 \
        /usr/bin/env time -f '%M' -o "$output_directory/peak.$run" \
        "$project_root/tools/run-limited.sh" "$compiler" analyze --stdio < "$output_directory/input.jsonl" > "$output_directory/output.jsonl" 2> "$output_directory/error.txt" || {
        echo "analysis-memory: analyze --stdio over src/orc_main.ab failed" >&2
        sed -n '1,20p' "$output_directory/error.txt" >&2
        exit 1
    }
    measured=$(tail -n 1 "$output_directory/peak.$run")
    if [[ -z $peak || $measured -lt $peak ]]; then peak=$measured; fi
done
node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n");
const result = JSON.parse(lines[1]).result;
let named = 0;
for (const document of result.documents) for (const occurrence of document.occurrences) if (occurrence.declarationId) named += 1;
if (named < 100000) throw new Error(`only ${named} occurrences name a declaration`);
' "$output_directory/output.jsonl"

edit_peak=""
edit_live=""
for run in 1 2; do
    ABLA_SYSROOT="$root" ABLA_COMPILE_EVAL=jit ABLA_COMPILER_MEMORY_TRACE=1 ABLA_MAX_MEMORY_MB=6144 ABLA_MAX_SECONDS=1800 ABLA_MAX_CPU_SECONDS=900 \
        /usr/bin/env time -f '%M' -o "$output_directory/edit-peak" \
        "$project_root/tools/run-limited.sh" "$compiler" analyze --stdio < "$output_directory/edit-input.jsonl" > "$output_directory/edit-output.jsonl" 2> "$output_directory/edit-error.txt" || {
        echo "analysis-memory: the edit loop over src/orc_main.ab failed" >&2
        sed -n '1,20p' "$output_directory/edit-error.txt" >&2
        exit 1
    }
    measured=$(tail -n 1 "$output_directory/edit-peak")
    if [[ -z $edit_peak || $measured -lt $edit_peak ]]; then edit_peak=$measured; fi
    live=$(sed -n 's/^abla-analysis-peak-live //p' "$output_directory/edit-error.txt" | tail -n 1)
    [[ -n $live ]] || { echo "analysis-memory: the service did not report its peak live heap (abla-analysis-peak-live)" >&2; exit 1; }
    edit_live=$live
    # A second run only when the first is over the resident bound (load can raise it; the lowest counts).
    (( edit_peak <= edit_bound_kilobytes )) && break
done
node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").map((line) => JSON.parse(line));
const last = lines.find((line) => line.id === 7).result;
const edited = last.documents.find((document) => document.uri.endsWith("/src/module_paths.ab"));
if (!edited || edited.version !== 2 || !edited.text.includes("unusedEdit = 2")) throw new Error("the last analysis does not carry the edited module at its last version");
let named = 0;
for (const document of last.documents) for (const occurrence of document.occurrences) if (occurrence.declarationId) named += 1;
if (named < 100000) throw new Error(`only ${named} occurrences name a declaration after the edits`);
' "$output_directory/edit-output.jsonl"

if (( edit_live > edit_live_bound_bytes )); then
    echo "analysis-memory: the edit loop's live heap peaked at $edit_live bytes, over $edit_live_bound_bytes: what keeps the previous answer alive while the next is built?" >&2
    exit 1
fi
if (( edit_peak > edit_bound_kilobytes )); then
    echo "analysis-memory: the edit loop peaked at $edit_peak kB, over $edit_bound_kilobytes kB: what keeps the previous answer alive while the next is built?" >&2
    exit 1
fi
if (( peak > bound_kilobytes )); then
    echo "analysis-memory: analyze --stdio over src/orc_main.ab peaked at $peak kB, over $bound_kilobytes kB: what keeps the path or a string per occurrence (resolvedNames, the occurrence index)?" >&2
    exit 1
fi
echo "analysis memory: analyze --stdio over the compiler's own source peaks at $peak kB (bound $bound_kilobytes kB), and after edits at $edit_peak kB (bound $edit_bound_kilobytes kB), with a live heap of $edit_live bytes (bound $edit_live_bound_bytes)"
