#!/usr/bin/env bash
# W_UNUSED_PARAMETER, opt-in (--warn-unused-parameters; the editor's initialize `unusedParameters`): a parameter of a function or
# method that sema's lookups never found, unless it is `_`-prefixed, or the signature is fixed from outside (`main`, an interface
# implementation, an exported or external function). tests/cases/unused-parameters/main.ab has two (ignored, spare). Without the
# flag there is none. The editor gives the same two as warnings with the unnecessary tag.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
work="$project_root/build/unused-parameters"
rm -rf "${work:?}"
mkdir -p "$work"
cp "$project_root/tests/cases/unused-parameters/main.ab" "$work/"
fail() { echo "unused-parameters: $1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }

(cd "$work" && "$compiler" build main.ab -o program --fast --warn-unused-parameters) > "$work/warn.log" 2>&1 || fail "main.ab didn't build" "$work/warn.log"
grep '^warning\[W_UNUSED_PARAMETER\]' "$work/warn.log" | sort > "$work/warnings.txt" || true
cat > "$work/expected.txt" <<'TXT'
warning[W_UNUSED_PARAMETER]: main.ab: parameter `ignored` is never used
warning[W_UNUSED_PARAMETER]: main.ab: parameter `spare` is never used
TXT
diff "$work/expected.txt" "$work/warnings.txt" > "$work/warn.diff" || fail "the warnings differ" "$work/warn.diff"
(cd "$work" && "$compiler" build main.ab -o program --fast) > "$work/plain.log" 2>&1 || fail "plain build failed" "$work/plain.log"
! grep -q W_UNUSED_PARAMETER "$work/plain.log" || fail "a warning without --warn-unused-parameters" "$work/plain.log"

node -e '
const fs = require("fs");
const [dir, out] = process.argv.slice(1);
const params = { workspaceRoots: [dir], clientName: "unused-parameters", clientVersion: "1", analysisMode: "graph-v2", unusedParameters: true };
const lines = [{ schema: 1, id: 1, method: "initialize", params },
  { schema: 1, id: 2, method: "analyze", params: { roots: [dir + "/main.ab"] } },
  { schema: 1, id: 3, method: "shutdown", params: {} }];
fs.writeFileSync(out, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
' "$work" "$work/editor.jsonl"
"$compiler" analyze --stdio < "$work/editor.jsonl" > "$work/editor.out" 2> "$work/editor.err" || fail "the editor service failed" "$work/editor.err"
node -e '
const fs = require("fs");
const answers = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").map(JSON.parse);
const fail = (message) => { console.error("editor: " + message); process.exit(1); };
const document = answers.find((a) => a.id === 2).result.documents.find((d) => d.uri.endsWith("/main.ab"));
const warned = document.diagnostics.filter((d) => d.code === "W_UNUSED_PARAMETER");
if (warned.length !== 2) fail("not two warnings: " + JSON.stringify(document.diagnostics));
const bytes = Buffer.from(document.text);
const names = [];
for (const d of warned) {
  if (d.severity !== "warning" || JSON.stringify(d.tags) !== "[\"unnecessary\"]") fail("severity or tags: " + JSON.stringify(d));
  const name = bytes.subarray(d.range.start, d.range.end).toString();
  if (name !== "ignored" && name !== "spare") fail("the range holds " + JSON.stringify(name));
  names.push(name);
}
if (names.sort().join() !== "ignored,spare") fail("names " + names);
' "$work/editor.out"
echo "unused-parameters ok"
