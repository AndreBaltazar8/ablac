#!/usr/bin/env bash
# W_UNUSED_LOCAL, opt-in (--warn-unused-locals; the editor's initialize `unusedLocals`): a `val` or `var` statement that sema's
# lookups never found. tests/cases/unused-locals/main.ab has two (dead, stale) among locals that are read, written, interpolated,
# captured by a closure, passed on, or `_`-prefixed. Without the flag there is none. The editor's analysis gives the same two as
# warnings on the name, with the unnecessary tag and a fix that renames the name with a `_`.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
work="$project_root/build/unused-locals"
rm -rf "${work:?}"
mkdir -p "$work"
cp "$project_root/tests/cases/unused-locals/main.ab" "$work/"
fail() { echo "unused-locals: $1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }

(cd "$work" && "$compiler" build main.ab -o program --fast --warn-unused-locals) > "$work/warn.log" 2>&1 || fail "main.ab didn't build" "$work/warn.log"
grep '^warning\[W_UNUSED_LOCAL\]' "$work/warn.log" > "$work/warnings.txt" || true
cat > "$work/expected.txt" <<'TXT'
warning[W_UNUSED_LOCAL]: main.ab: `dead` is never used
warning[W_UNUSED_LOCAL]: main.ab: `stale` is never used
TXT
diff "$work/expected.txt" "$work/warnings.txt" > "$work/warn.diff" || fail "the warnings differ" "$work/warn.diff"
(cd "$work" && "$compiler" build main.ab -o program --fast) > "$work/plain.log" 2>&1 || fail "plain build failed" "$work/plain.log"
! grep -q W_UNUSED_LOCAL "$work/plain.log" || fail "a warning without --warn-unused-locals" "$work/plain.log"

node -e '
const fs = require("fs");
const [dir, out, locals] = process.argv.slice(1);
const params = { workspaceRoots: [dir], clientName: "unused-locals", clientVersion: "1", analysisMode: "graph-v2" };
if (locals === "true") params.unusedLocals = true;
const lines = [{ schema: 1, id: 1, method: "initialize", params },
  { schema: 1, id: 2, method: "analyze", params: { roots: [dir + "/main.ab"] } },
  { schema: 1, id: 3, method: "shutdown", params: {} }];
fs.writeFileSync(out, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
' "$work" "$work/editor.jsonl" true
"$compiler" analyze --stdio < "$work/editor.jsonl" > "$work/editor.out" 2> "$work/editor.err" || fail "the editor service failed" "$work/editor.err"
node -e '
const fs = require("fs");
const answers = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").map(JSON.parse);
const fail = (message) => { console.error("editor: " + message); process.exit(1); };
const document = answers.find((a) => a.id === 2).result.documents.find((d) => d.uri.endsWith("/main.ab"));
const warned = document.diagnostics.filter((d) => d.code === "W_UNUSED_LOCAL");
if (warned.length !== 2) fail("not two warnings: " + JSON.stringify(document.diagnostics));
const bytes = Buffer.from(document.text);
const names = [];
for (const d of warned) {
  if (d.severity !== "warning" || JSON.stringify(d.tags) !== "[\"unnecessary\"]") fail("severity or tags: " + JSON.stringify(d));
  const name = bytes.subarray(d.range.start, d.range.end).toString();
  const fix = (d.fixes || [])[0];
  if (!fix || fix.kind !== "replace" || fix.edits.length !== 1 || fix.edits[0].newText !== "_" + name ||
      fix.edits[0].range.start !== d.range.start || fix.edits[0].range.end !== d.range.end) fail("fix: " + JSON.stringify(d.fixes));
  names.push(name);
}
if (names.sort().join() !== "dead,stale") fail("the warned names are " + names);
' "$work/editor.out" || fail "the editor's unused-local warnings differ"
node -e '
const fs = require("fs");
const lines = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").map(JSON.parse);
lines[0].params.unusedLocals = false;
fs.writeFileSync(process.argv[2], lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
' "$work/editor.jsonl" "$work/editor-off.jsonl"
"$compiler" analyze --stdio < "$work/editor-off.jsonl" > "$work/editor-off.out" 2> "$work/editor-off.err" || fail "the editor service failed" "$work/editor-off.err"
! grep -q '"W_UNUSED_LOCAL"' "$work/editor-off.out" || fail "the editor warned without the option" "$work/editor-off.out"
echo "unused-locals: 2 warnings (dead, stale) and none for a read, written, interpolated, captured or passed local or a _ name, none without the flag; the editor's analysis gives them as warnings on the name with the unnecessary tag and a _-rename fix, and none without unusedLocals"
