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
        '{"schema":1,"id":3,"method":"document/open","params":{"uri":"file:///tmp/abla-analysis-caller.ab","version":2,"text":"val callback = greet\nfun main(input: string): string {\n    val message = greet(input)\n    message\n}\n"}}' \
        '{"schema":1,"id":4,"method":"document/open","params":{"uri":"file:///tmp/abla-analysis-broken.ab","version":1,"text":"fun broken: int = missing\n"}}' \
        '{"schema":1,"id":5,"method":"analyze","params":{}}' \
        '{"schema":1,"id":6,"method":"document/change","params":{"uri":"file:///tmp/abla-analysis-overlay.ab","version":6,"text":"fun stale: int = 0\n"}}' \
        '{"schema":1,"id":7,"method":"refactor/validate","params":{"baseRevision":"4","edits":[{"uri":"file:///tmp/abla-analysis-broken.ab","start":18,"end":25,"newText":"1"}],"invariants":["no-new-errors"]}}' \
        '{"schema":1,"id":8,"method":"refactor/validate","params":{"baseRevision":"4","edits":[{"uri":"file:///tmp/abla-analysis-caller.ab","start":15,"end":20,"newText":"unknownName"}],"invariants":["no-new-errors"]}}' \
        '{"schema":1,"id":9,"method":"shutdown","params":{}}' |
        "$compiler" analyze --stdio
)

node -e '
const lines = require("node:fs").readFileSync(0, "utf8").trim().split("\n").map(JSON.parse);
if (lines.length !== 9) throw new Error(`expected 9 responses, got ${lines.length}`);
const initialized = lines[0].result;
if (initialized.protocolVersion !== 1 || !initialized.capabilities.includes("declarations")) {
  throw new Error("analysis protocol negotiation failed");
}
const document = lines[4].result.documents[0];
if (document.version !== 7 || document.text !== "// café\nfun greet(name: string): string = name\n") {
  throw new Error("unsaved UTF-8 overlay was not preserved");
}
if (document.symbols[0].name !== "greet" || document.symbols[0].selectionRange.start !== 13) {
  throw new Error("compiler byte spans were not returned for the UTF-8 declaration");
}
const caller = lines[4].result.documents[1];
const call = caller.occurrences.find((occurrence) => occurrence.name === "greet");
if (call?.declarationId !== document.symbols[0].id) {
  throw new Error("semantic call was not linked to its cross-file declaration");
}
const greetReferences = caller.occurrences.filter((occurrence) => occurrence.name === "greet");
if (greetReferences.length !== 2 || greetReferences.some((occurrence) => occurrence.declarationId !== document.symbols[0].id)) {
  throw new Error("semantic function-value reference was not linked to its declaration");
}
for (const localName of ["input", "message"]) {
  const symbol = caller.symbols.find((candidate) => candidate.name === localName);
  const occurrences = caller.occurrences.filter((occurrence) => occurrence.name === localName);
  if (!symbol || occurrences.length !== 2 || occurrences.some((occurrence) => occurrence.declarationId !== symbol.id)) {
    throw new Error(`local symbol ${localName} did not retain one lexical identity`);
  }
}
const semantic = lines[4].result.documents[2].diagnostics[0];
if (semantic?.code !== "E_SEMANTIC" || semantic.range.start !== 18) {
  throw new Error("semantic diagnostic was not routed to its source byte span");
}
if (lines[5].error?.code !== "stale_document") {
  throw new Error("stale overlay version was accepted");
}
if (lines[6].result?.valid !== true || !lines[6].result?.snapshot) {
  throw new Error("a diagnostic-removing prospective edit was rejected");
}
if (lines[7].result?.valid !== false) {
  throw new Error("a diagnostic-introducing prospective edit was accepted");
}
' <<<"$responses"

printf '%s\n' 'analysis service: protocol, overlays, UTF-8 spans, semantic calls/diagnostics, stale versions passed'
