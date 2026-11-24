#!/usr/bin/env bash
set -euo pipefail

project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
if [[ $compiler != /* ]]; then
    compiler="$project_root/$compiler"
fi

# One graph-v1 session (the only analysis there is since #832): each case selects its project entry with
# `analyze {roots}`, which moves the revision on (5 opens: 6, then 7, 8 and 9), and validates edits against it.
responses=$(
    printf '%s\n' \
        '{"schema":1,"id":1,"method":"initialize","params":{"workspaceRoots":[],"clientName":"analysis-test","clientVersion":"1","analysisMode":"graph-v1"}}' \
        '{"schema":1,"id":2,"method":"document/open","params":{"uri":"file:///tmp/abla-analysis-overlay.ab","version":7,"text":"// café\nfun greet(name: string): string = name\n"}}' \
        '{"schema":1,"id":3,"method":"document/open","params":{"uri":"file:///tmp/abla-analysis-caller.ab","version":2,"text":"import \"abla-analysis-overlay.ab\"\nval callback = greet\nfun main(input: string): string {\n    val message = greet(input)\n    message\n}\n"}}' \
        '{"schema":1,"id":4,"method":"document/open","params":{"uri":"file:///tmp/abla-analysis-broken.ab","version":1,"text":"fun broken: int = missing\n"}}' \
        '{"schema":1,"id":5,"method":"document/open","params":{"uri":"file:///tmp/malformed.ab","version":1,"text":"fun broken(: int = 1\n"}}' \
        '{"schema":1,"id":6,"method":"document/open","params":{"uri":"file:///tmp/abla-analysis-entry.ab","version":1,"text":"fun main: int = 0\n"}}' \
        '{"schema":1,"id":7,"method":"analyze","params":{"roots":["/tmp/abla-analysis-caller.ab"]}}' \
        '{"schema":1,"id":8,"method":"document/change","params":{"uri":"file:///tmp/abla-analysis-overlay.ab","version":6,"text":"fun stale: int = 0\n"}}' \
        '{"schema":1,"id":9,"method":"refactor/validate","params":{"baseRevision":"6","edits":[{"uri":"file:///tmp/abla-analysis-caller.ab","start":49,"end":54,"newText":"unknownName"}],"invariants":["no-new-errors"]}}' \
        '{"schema":1,"id":10,"method":"analyze","params":{"roots":["/tmp/abla-analysis-broken.ab"]}}' \
        '{"schema":1,"id":11,"method":"refactor/validate","params":{"baseRevision":"7","edits":[{"uri":"file:///tmp/abla-analysis-broken.ab","start":18,"end":25,"newText":"1"}],"invariants":["no-new-errors"]}}' \
        '{"schema":1,"id":12,"method":"refactor/validate","params":{"baseRevision":"7","edits":[{"uri":"file:///tmp/abla-analysis-broken.ab","start":18,"end":25,"newText":"otherMissing"}],"invariants":["no-new-errors"]}}' \
        '{"schema":1,"id":13,"method":"refactor/validate","params":{"baseRevision":"7","edits":[{"uri":"file:///tmp/abla-analysis-undeclared.ab","start":0,"end":0,"newText":"fun undeclared: int = 42\n"}],"invariants":["no-new-errors"]}}' \
        '{"schema":1,"id":14,"method":"analyze","params":{"roots":["/tmp/abla-analysis-entry.ab"]}}' \
        '{"schema":1,"id":15,"method":"refactor/validate","params":{"baseRevision":"8","createdDocuments":[{"uri":"file:///tmp/abla-analysis-created.ab","text":""}],"edits":[{"uri":"file:///tmp/abla-analysis-created.ab","start":0,"end":0,"newText":"fun created: int = 42\n"},{"uri":"file:///tmp/abla-analysis-entry.ab","start":0,"end":0,"newText":"import \"abla-analysis-created.ab\"\n"}],"invariants":["no-new-errors"]}}' \
        '{"schema":1,"id":16,"method":"refactor/validate","params":{"baseRevision":"8","createdDocuments":[{"uri":"file:///tmp/abla-analysis-invalid-created.ab","text":""}],"edits":[{"uri":"file:///tmp/abla-analysis-invalid-created.ab","start":0,"end":0,"newText":"fun invalid: int = missing\n"},{"uri":"file:///tmp/abla-analysis-entry.ab","start":0,"end":0,"newText":"import \"abla-analysis-invalid-created.ab\"\n"}],"invariants":["no-new-errors"]}}' \
        '{"schema":1,"id":17,"method":"analyze","params":{"roots":["/tmp/malformed.ab"]}}' \
        '{"schema":1,"id":18,"method":"shutdown","params":{}}' |
        "$compiler" analyze --stdio
)

node -e '
const lines = require("node:fs").readFileSync(0, "utf8").trim().split("\n").map(JSON.parse);
if (lines.length !== 18) throw new Error(`expected 18 responses, got ${lines.length}`);
const initialized = lines[0].result;
if (initialized.protocolVersion !== 1 || !initialized.capabilities.includes("declarations")) {
  throw new Error("analysis protocol negotiation failed");
}
const byUri = (index, name) => lines[index].result.documents.find((d) => d.uri === `file:///tmp/${name}`);
const revisions = [6, 9, 13, 16].map((index) => lines[index].result.revision).join(",");
if (revisions !== "6,7,8,9") throw new Error(`the revisions the validations name are not the analyses: ${revisions}`);
const document = byUri(6, "abla-analysis-overlay.ab");
if (document?.version !== 7 || document.text !== "// café\nfun greet(name: string): string = name\n") {
  throw new Error("unsaved UTF-8 overlay was not preserved");
}
if (document.symbols[0].name !== "greet" || document.symbols[0].selectionRange.start !== 13) {
  throw new Error("compiler byte spans were not returned for the UTF-8 declaration");
}
const caller = byUri(6, "abla-analysis-caller.ab");
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
// An analysis holds its entry and what it imports, nothing else open: broken.ab and malformed.ab both declare
// `broken`, and neither is in the analysis of the other.
if (byUri(6, "abla-analysis-broken.ab") || byUri(6, "malformed.ab") || byUri(9, "malformed.ab")) {
  throw new Error("an analysis held a document its entry does not import");
}
const brokenDiagnostics = byUri(9, "abla-analysis-broken.ab").diagnostics;
if (brokenDiagnostics.length !== 1 || brokenDiagnostics[0].code !== "E_SEMANTIC" || brokenDiagnostics[0].range.start !== 18) {
  throw new Error("semantic diagnostic was not routed to its source byte span (alone)");
}
const parserDiagnostics = byUri(16, "malformed.ab").diagnostics;
if (parserDiagnostics.length !== 4 || parserDiagnostics[0]?.range.start !== 11) {
  throw new Error("parser diagnostics did not preserve individual source ranges");
}
if (lines[7].error?.code !== "stale_document") {
  throw new Error("stale overlay version was accepted");
}
if (lines[8].result?.valid !== false) {
  throw new Error("a diagnostic-introducing prospective edit was accepted");
}
if (lines[10].result?.valid !== true || !lines[10].result?.snapshot) {
  throw new Error("a diagnostic-removing prospective edit was rejected");
}
if (lines[11].result?.valid !== false) {
  throw new Error("a replacement diagnostic was hidden by an unchanged total error count");
}
if (lines[12].result?.valid !== false || lines[12].result?.reason !== "edit targets an unanalyzed document") {
  throw new Error("an edit created an undeclared document implicitly");
}
const created = lines[14].result?.snapshot?.documents.find((d) => d.uri === "file:///tmp/abla-analysis-created.ab");
if (lines[14].result?.valid !== true || created?.symbols[0]?.name !== "created") {
  throw new Error("an explicitly created document was not included in prospective analysis");
}
if (lines[15].result?.valid !== false) {
  throw new Error("a diagnostic-introducing created document was accepted");
}
' <<<"$responses"

# The analysis sees the code the build compiles: receiver members called by
# plain name, literals typed from their declaration and lambdas typed from the
# array they are appended to analyze without diagnostics, as they build.
rewrites=$(
    printf '%s\n' \
        '{"schema":1,"id":1,"method":"initialize","params":{"workspaceRoots":[],"clientName":"analysis-test","clientVersion":"1","analysisMode":"graph-v1"}}' \
        '{"schema":1,"id":2,"method":"document/open","params":{"uri":"file:///tmp/abla-analysis-rewrites.ab","version":1,"text":"class Shape(val w: int, var h: int) {\n    fun area(): int = w * h\n    fun describe(): string = \"area ${area()}\"\n}\n\nfun main: int {\n    val rows: array<array<int?>> = [[1, null], []]\n    val handlers: array<(int) -> int> = []\n    handlers.append({ x -> x + 1 })\n    Shape(3, 4).describe().size + rows.size + handlers[0](1)\n}\n"}}' \
        '{"schema":1,"id":3,"method":"analyze","params":{"roots":["/tmp/abla-analysis-rewrites.ab"]}}' \
        '{"schema":1,"id":4,"method":"shutdown","params":{}}' |
        "$compiler" analyze --stdio
)
node -e '
const lines = require("node:fs").readFileSync(0, "utf8").trim().split("\n").map(JSON.parse);
const document = lines[2].result.documents[0];
if (document.diagnostics.length !== 0) {
  throw new Error("analysis differs from the build: " + JSON.stringify(document.diagnostics));
}
if (!document.symbols.some((symbol) => symbol.name === "Shape")) {
  throw new Error("the rewritten document lost its symbols");
}
' <<<"$rewrites"


# A long session, as abla-lsp's compiler integration test drives it (tests/cases/analysis-service/refactor-session, recorded from that test's own
# requests: initialize in graph-v2, analyze, six refactor/validate, shutdown), its six validations repeated ANALYSIS_SESSION_ROUNDS times (default 10)
# in the one session. The macOS lanes of ci.yml run that script directly (bash only, no node): the released v0.2.68 service died with SIGBUS in this session on both Macs
# (found by abla-lsp's CI, not ours; #1207) while Linux answered it in 3 s. Every reply must come, each validation valid, the service exit 0.
"$project_root/tools/test-analysis-refactor-session.sh" "$compiler" "${ANALYSIS_SESSION_ROUNDS:-10}"

printf '%s\n' 'analysis service: protocol, overlays, UTF-8 spans, semantic calls/diagnostics, created documents, stale versions, build rewrites, a long refactor session passed'
