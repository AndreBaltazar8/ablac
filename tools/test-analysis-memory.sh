#!/usr/bin/env bash
# The editor's cost on a program of the compiler's own size (#814): `ablac analyze --stdio` in graph mode over src/orc_main.ab
# (the compiler's source, 306,000 name occurrences) peaks in resident memory under a bound. Every occurrence once held an
# identity string with the source path in it, and the occurrence index a key with the path: 2,270,000 kB (the compiler of
# before the fix, 2,249,000 on today's source); with the identities shared, no path in the index keys, and the types shared,
# about 2,060,000 (1,985,000 from the fixed path). The service's answer must also name a declaration for the occurrences it names (a sanity check that the
# run analysed something).
#
# The editor keeps the source path in its identities (they are what the client sees), so the peak follows the length of the
# checkout's path: the source is analysed from a copy at a path of fixed length, and the lowest of up to three runs counts (the
# runs differ by a few MB; a checkout path 25 characters longer is ~80 MB). The bound, 2,150,000, sits between the fixed compiler's level
# and the old one's (record line: 2,030,000 kB of the commit that named built-ins, locals, types and field assignments and exported documentation; see below).
#
# The record line moved from 1,940,000 to 2,030,000 kB (bound 2,040,000 to 2,150,000) with the editor stack that names built-ins, locals, type
# names and assigned fields and exports documentation (d8347f69 against 1bd36ddd, the same source analysed by a stage-1 build of each, three
# runs alternately: 1,937,432 / 1,901,980 / 1,937,476 kB before, 2,045,552 / 2,028,672 / 2,033,344 after). Named occurrences of the compiler's
# own source went from 265,798 to 305,054 of 323,000 (+15%) and the answer's occurrence text from 47.8 to 51.9 MB; the heap reachable at the
# end of the analysis (ABLA_COMPILER_MEMORY_TRACE) rose 17-32 MB (808.6, 816.1 MB before; 826.0, 848.8 MB after) and what the service keeps after
# it, 440-443 against 448 MB. The peak moved by more than that because a collection that falls a little later in the analysis catches the
# answer being built with more garbage in the heap: a run of the same commit moves by up to 36 MB. The bound keeps the margin above the record
# that it had (about 6%) and stays 5% below the retention it guards against (2,270,000 kB, an identity string per occurrence): the retained
# answer is also bounded by reachable bytes, below.
#
# The editor then edits: the same service analyses after an edit to a module many modules depend on, after the same text again,
# and after a second edit (the loop of a client at a keystroke). Each analysis once kept the previous answer (a tree of ~2 GB)
# alive while it built the next, and the loop peaked at 3.2-3.9 GB; the previous generation is now released first, and
# the answer's occurrences are kept as text, so the loop peaks near the first analysis's level. Its bound, 2,200,000 kB (1,930,000 measured), sits
# between that and the old behaviour's; the final answer must carry the edited module at its last version.
#
# The service collects after as much growth as it holds, once it holds a project (analysis_graph.ab, bootstrapAnalysisCollectionGrowth: 512 MB
# for the compiler's own source, 256 before): an edit's CPU fell by a fifth to a third, and the loop's resident peak rose from 2.03-2.04 GB
# to 2.23-2.38 GB (three runs), so its bound moved from 2,200,000 to 2,650,000 kB. The first analysis, which holds nothing, keeps the
# compiler's step and its bound.
#
# The loop is bounded twice, because neither number alone follows the source as it grows. Its resident size, bound 2,650,000 kB (the lowest of
# two runs when the first is over it), is what an editor's machine pays; but it is not a stable measure (the same compiler peaked at 2.03 GB alone
# and 2.29 GB in a loaded suite run: it is about twice the reachable heap, the rest is what the heap holds between collections). What the
# loop must not do is keep the previous answer: so a third run, with ABLA_COMPILER_MEMORY_TRACE set, has the service collect the heap and
# print the bytes still reachable at the phase boundaries of each analysis (bootstrapAnalysisSampleMemory), and the loop's peak is bounded to
# 1.35 times the first, cold analysis's in the same run. That is a ratio, so it follows the source as it grows (the cold analysis was 0.68 GB on the
# compiler's own source and the loop's peak 0.74 to 0.81 GB, 1.08 to 1.19 times it; an absolute bound of 1,030,000,000 bytes on live bytes read between
# collections, which hold the garbage made since the last one, tripped at 1,031,677,366 after 520 lines of source were added), and a loop that
# keeps the previous answer (about twice the cold analysis) is far over it.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
output_directory="$project_root/build/analysis-memory"
bound_kilobytes=2150000
edit_bound_kilobytes=2650000
edit_retention_percent=135
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
for run in 1 2 3; do
    ABLA_SYSROOT="$root" ABLA_COMPILE_EVAL=jit ABLA_MAX_MEMORY_MB=4096 ABLA_MAX_SECONDS=1800 ABLA_MAX_CPU_SECONDS=600 \
        /usr/bin/env time -f '%M' -o "$output_directory/peak.$run" \
        "$project_root/tools/run-limited.sh" "$compiler" analyze --stdio < "$output_directory/input.jsonl" > "$output_directory/output.jsonl" 2> "$output_directory/error.txt" || {
        echo "analysis-memory: analyze --stdio over src/orc_main.ab failed" >&2
        sed -n '1,20p' "$output_directory/error.txt" >&2
        exit 1
    }
    measured=$(tail -n 1 "$output_directory/peak.$run")
    if [[ -z $peak || $measured -lt $peak ]]; then peak=$measured; fi
    # A further run only when the lowest so far is over the bound (load can raise a run; the lowest counts).
    (( peak <= bound_kilobytes )) && break
done
node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n");
const result = JSON.parse(lines[1]).result;
let named = 0;
for (const document of result.documents) for (const occurrence of document.occurrences) if (occurrence.declarationId) named += 1;
if (named < 100000) throw new Error(`only ${named} occurrences name a declaration`);
' "$output_directory/output.jsonl"

edit_peak=""
for run in 1 2 3; do
    ABLA_SYSROOT="$root" ABLA_COMPILE_EVAL=jit ABLA_MAX_MEMORY_MB=6144 ABLA_MAX_SECONDS=1800 ABLA_MAX_CPU_SECONDS=900 \
        /usr/bin/env time -f '%M' -o "$output_directory/edit-peak" \
        "$project_root/tools/run-limited.sh" "$compiler" analyze --stdio < "$output_directory/edit-input.jsonl" > "$output_directory/edit-output.jsonl" 2> "$output_directory/edit-error.txt" || {
        echo "analysis-memory: the edit loop over src/orc_main.ab failed" >&2
        sed -n '1,20p' "$output_directory/edit-error.txt" >&2
        exit 1
    }
    measured=$(tail -n 1 "$output_directory/edit-peak")
    if [[ -z $edit_peak || $measured -lt $edit_peak ]]; then edit_peak=$measured; fi
    # A second run only when the first is over the resident bound (load can raise it; the lowest counts).
    (( edit_peak <= edit_bound_kilobytes )) && break
done
# The traced run: what is reachable at the phase boundaries, the cold analysis's peak against the loop's.
ABLA_SYSROOT="$root" ABLA_COMPILE_EVAL=jit ABLA_COMPILER_MEMORY_TRACE=1 ABLA_MAX_MEMORY_MB=6144 ABLA_MAX_SECONDS=1800 ABLA_MAX_CPU_SECONDS=900 \
    "$project_root/tools/run-limited.sh" "$compiler" analyze --stdio < "$output_directory/edit-input.jsonl" > "$output_directory/traced-output.jsonl" 2> "$output_directory/traced-error.txt" || {
    echo "analysis-memory: the traced edit loop over src/orc_main.ab failed" >&2
    sed -n '1,20p' "$output_directory/traced-error.txt" >&2
    exit 1
}
read -r first_live loop_live < <(awk '/^abla-analysis-memory / { live = $NF + 0; if (!cold_done && live > first) first = live; if (live > peak) peak = live; if ($2 == "answer" && $3 == "built") cold_done = 1 } END { print first + 0, peak + 0 }' "$output_directory/traced-error.txt")
if (( first_live == 0 || loop_live == 0 )); then
    echo "analysis-memory: the service did not report the live heap at its phases (abla-analysis-memory)" >&2
    exit 1
fi
node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").map((line) => JSON.parse(line));
const last = lines.find((line) => line.id === 7).result;
const edited = last.documents.find((document) => document.uri.endsWith("/src/module_paths.ab"));
if (!edited || edited.version !== 2 || !edited.text.includes("unusedEdit = 2")) throw new Error("the last analysis does not carry the edited module at its last version");
let named = 0;
for (const document of last.documents) for (const occurrence of document.occurrences) if (occurrence.declarationId) named += 1;
if (named < 100000) throw new Error(`only ${named} occurrences name a declaration after the edits`);
' "$output_directory/edit-output.jsonl"

if (( loop_live * 100 > first_live * edit_retention_percent )); then
    echo "analysis-memory: the edit loop's reachable heap peaked at $loop_live bytes, over $edit_retention_percent% of the cold analysis's $first_live: what keeps the previous answer alive while the next is built?" >&2
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
echo "analysis memory: analyze --stdio over the compiler's own source peaks at $peak kB (bound $bound_kilobytes kB), and after edits at $edit_peak kB (bound $edit_bound_kilobytes kB), with a reachable heap of $loop_live bytes against the cold analysis's $first_live (bound $edit_retention_percent%)"
