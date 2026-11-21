#!/usr/bin/env bash
# W_UNUSED_DECLARATION, opt-in (--warn-unused-declarations; the editor's initialize `unusedDeclarations`): a top-level function or
# value that nothing in the build names. tests/cases/unused-declarations/main.ab has four (neverCalled, neverRead, onlyItself, and the private hidden; a project that declares a package has only hidden)
# among declarations that are called, read, passed as a value, run for their effect, `_`-prefixed, `main`, or named by another
# file of the project (other.ab). Without the flag there is none. The editor gives the same three as warnings with the
# unnecessary tag.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
# Outside the checkout: the project's other files are scanned from the checkout's root, where tests/cases holds copies of these.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp "$project_root"/tests/cases/unused-declarations/*.ab "$work/"
fail() { echo "unused-declarations: $1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }

(cd "$work" && "$compiler" build main.ab -o program --fast --warn-unused-declarations) > "$work/warn.log" 2>&1 || fail "main.ab didn't build" "$work/warn.log"
grep '^warning\[W_UNUSED_DECLARATION\]' "$work/warn.log" | sort > "$work/warnings.txt" || true
cat > "$work/expected.txt" <<'TXT'
warning[W_UNUSED_DECLARATION]: main.ab: function `neverCalled` is never used
warning[W_UNUSED_DECLARATION]: main.ab: function `onlyItself` is never used
warning[W_UNUSED_DECLARATION]: main.ab: private function `hidden` is never used
warning[W_UNUSED_DECLARATION]: main.ab: value `neverRead` is never used
TXT
diff "$work/expected.txt" "$work/warnings.txt" > "$work/warn.diff" || fail "the warnings differ" "$work/warn.diff"
(cd "$work" && "$compiler" build main.ab -o program --fast) > "$work/plain.log" 2>&1 || fail "plain build failed" "$work/plain.log"
! grep -q W_UNUSED_DECLARATION "$work/plain.log" || fail "a warning without --warn-unused-declarations" "$work/plain.log"

node -e '
const fs = require("fs");
const [dir, out] = process.argv.slice(1);
const params = { workspaceRoots: [dir], clientName: "unused-declarations", clientVersion: "1", analysisMode: "graph-v2", unusedDeclarations: true };
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
const warned = document.diagnostics.filter((d) => d.code === "W_UNUSED_DECLARATION");
if (warned.length !== 4) fail("not four warnings: " + JSON.stringify(document.diagnostics));
const bytes = Buffer.from(document.text);
const names = [];
for (const d of warned) {
  if (d.severity !== "warning" || JSON.stringify(d.tags) !== "[\"unnecessary\"]") fail("severity or tags: " + JSON.stringify(d));
  const text = bytes.subarray(d.range.start, d.range.end).toString();
  const name = ["neverCalled", "neverRead", "onlyItself", "hidden"].find((n) => text.includes(n));
  if (!name) fail("the range holds " + JSON.stringify(text));
  names.push(name);
}
if (names.sort().join() !== "hidden,neverCalled,neverRead,onlyItself") fail("names " + names);
' "$work/editor.out"
# A project that declares a package (abla.toml with a name): its public declarations are for its users, only `private` ones count.
printf 'name = "lib"\nversion = "0.0.1"\nentry = "main.ab"\n' > "$work/abla.toml"
(cd "$work" && "$compiler" build main.ab -o program --fast --warn-unused-declarations) > "$work/package.log" 2>&1 || fail "the package didn't build" "$work/package.log"
[[ $(grep -c '^warning\[W_UNUSED_DECLARATION\]' "$work/package.log") == 1 ]] && grep -q 'private function `hidden`' "$work/package.log" || fail "a package reports more or less than its private declaration" "$work/package.log"
echo "unused-declarations ok"
