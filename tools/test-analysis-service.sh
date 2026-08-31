#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
if [[ $compiler != /* ]]; then
    compiler="$project_root/$compiler"
fi

responses=$(
    printf '%s\n' \
        '{"schema":1,"id":1,"method":"initialize","params":{"workspaceRoots":[],"clientName":"analysis-test","clientVersion":"1"}}' \
        '{"schema":1,"id":2,"method":"document/open","params":{"uri":"file:///tmp/abla-analysis-overlay.ab","version":7,"text":"// café\nfun greet(name: string): string = name\n"}}' \
        '{"schema":1,"id":3,"method":"document/open","params":{"uri":"file:///tmp/abla-analysis-caller.ab","version":2,"text":"fun main: string = greet(\"Abla\")\n"}}' \
        '{"schema":1,"id":4,"method":"analyze","params":{}}' \
        '{"schema":1,"id":5,"method":"document/change","params":{"uri":"file:///tmp/abla-analysis-overlay.ab","version":6,"text":"fun stale: int = 0\n"}}' \
        '{"schema":1,"id":6,"method":"shutdown","params":{}}' |
        "$compiler" analyze --stdio
)

node -e '
const lines = require("node:fs").readFileSync(0, "utf8").trim().split("\n").map(JSON.parse);
if (lines.length !== 6) throw new Error(`expected 6 responses, got ${lines.length}`);
const initialized = lines[0].result;
if (initialized.protocolVersion !== 1 || !initialized.capabilities.includes("declarations")) {
  throw new Error("analysis protocol negotiation failed");
}
const document = lines[3].result.documents[0];
if (document.version !== 7 || document.text !== "// café\nfun greet(name: string): string = name\n") {
  throw new Error("unsaved UTF-8 overlay was not preserved");
}
if (document.symbols[0].name !== "greet" || document.symbols[0].selectionRange.start !== 13) {
  throw new Error("compiler byte spans were not returned for the UTF-8 declaration");
}
const caller = lines[3].result.documents[1];
const call = caller.occurrences.find((occurrence) => occurrence.name === "greet");
if (call?.declarationId !== document.symbols[0].id) {
  throw new Error("semantic call was not linked to its cross-file declaration");
}
if (lines[4].error?.code !== "stale_document") {
  throw new Error("stale overlay version was accepted");
}
' <<<"$responses"

printf '%s\n' 'analysis service: protocol, overlays, UTF-8 spans, semantic calls, stale versions passed'
