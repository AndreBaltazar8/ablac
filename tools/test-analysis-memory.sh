#!/usr/bin/env bash
# The editor's cost on a program of the compiler's own size (#814): `ablac analyze --stdio` in graph mode over src/orc_main.ab
# (the compiler's source, 306,000 name occurrences) peaks in resident memory under a bound. Every occurrence once held an
# identity string with the source path in it, and the occurrence index a key with the path: 2,270,000 kB; with the identities
# shared, no path in the index keys, and the types shared, about 2,015,000 kB. The bound is between them. The service's
# answer must also name a declaration for the occurrences it names (a sanity check that the run analysed something).
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
[[ $compiler == /* ]] || compiler="$PWD/$compiler"
output_directory="$project_root/build/analysis-memory"
bound_kilobytes=2150000
mkdir -p "$output_directory"
if ! /usr/bin/env time --version >/dev/null 2>&1; then
    echo "analysis-memory: needs GNU time (shell.nix has it)" >&2
    exit 1
fi

node -e '
const fs = require("fs");
const root = process.argv[1];
const lines = [
    { schema: 1, id: 1, method: "initialize", params: { workspaceRoots: [root], clientName: "analysis-memory", clientVersion: "1", analysisMode: "graph-v1" } },
    { schema: 1, id: 2, method: "analyze", params: { roots: [root + "/src/orc_main.ab"] } },
    { schema: 1, id: 3, method: "shutdown", params: {} },
];
fs.writeFileSync(process.argv[2], lines.map((line) => JSON.stringify(line)).join("\n") + "\n");
' "$project_root" "$output_directory/input.jsonl"

ABLA_SYSROOT="$project_root" ABLA_COMPILE_EVAL=jit ABLA_MAX_MEMORY_MB=4096 ABLA_MAX_SECONDS=1800 ABLA_MAX_CPU_SECONDS=600 \
    /usr/bin/env time -f '%M' -o "$output_directory/peak" \
    "$project_root/tools/run-limited.sh" "$compiler" analyze --stdio < "$output_directory/input.jsonl" > "$output_directory/output.jsonl" 2> "$output_directory/error.txt" || {
    echo "analysis-memory: analyze --stdio over src/orc_main.ab failed" >&2
    sed -n '1,20p' "$output_directory/error.txt" >&2
    exit 1
}
peak=$(tail -n 1 "$output_directory/peak")

node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n");
const result = JSON.parse(lines[1]).result;
let named = 0;
for (const document of result.documents) for (const occurrence of document.occurrences) if (occurrence.declarationId) named += 1;
if (named < 100000) throw new Error(`only ${named} occurrences name a declaration`);
' "$output_directory/output.jsonl"

if (( peak > bound_kilobytes )); then
    echo "analysis-memory: analyze --stdio over src/orc_main.ab peaked at $peak kB, over $bound_kilobytes kB: what keeps the path or a string per occurrence (resolvedNames, the occurrence index)?" >&2
    exit 1
fi
echo "analysis memory: analyze --stdio over the compiler's own source peaks at $peak kB (bound $bound_kilobytes kB)"
