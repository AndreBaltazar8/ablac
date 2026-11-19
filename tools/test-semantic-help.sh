#!/usr/bin/env bash
# Everyday semantic errors come with a `help:` line, under the machine-readable line they always had (sema.ab:
# bootstrapEverydayHelp, suggestVisibleName, suggestMember): a mismatched argument, result, assignment or initializer
# names both types and the usual conversion; a wrong argument count, a constructor argument and a mixed array literal
# say what is wrong; a misspelled function, local, method or field suggests the one close name code here can reach.
# The suggestion is conservative: one name, within 1 edit (2 past four characters), none on a tie, and never a name
# strict imports hide from the module (tests/cases/semantic-help/hidden.ab: helperOne is declared in a module it
# doesn't import).
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
output_directory="$project_root/build/semantic-help"
mkdir -p "$output_directory"

build() { # case: builds tests/cases/semantic-help/<case>.ab, which must fail, into <case>.log
    if "$compiler" build "$project_root/tests/cases/semantic-help/$1.ab" -o "$output_directory/$1" --fast \
        > "$output_directory/$1.log" 2>&1; then
        echo "semantic-help: tests/cases/semantic-help/$1.ab built; it is all mistakes" >&2
        exit 1
    fi
}
expect() { # case line
    grep -qxF "$2" "$output_directory/$1.log" || {
        echo "semantic-help: $1: no line \"$2\"" >&2
        cat "$output_directory/$1.log" >&2
        exit 1
    }
}
absent() { # case text
    if grep -qF "$2" "$output_directory/$1.log"; then
        echo "semantic-help: $1: \"$2\" should not be there" >&2
        cat "$output_directory/$1.log" >&2
        exit 1
    fi
}

build everyday
# The machine-readable lines are as they were.
for line in 'method.unknown:Point.lenght@' 'member:Point.lenght' 'function.argument:area@' 'assignment.type:d@' \
    'call.target:aera' 'identifier:widht@' 'function.arity:area' 'constructor.argument:Point' 'array.element-type' \
    'local.initializer:n' 'function.result:half:i64:string'; do
    grep -qF "error[E_SEMANTIC]: $line" "$output_directory/everyday.log" ||
        { echo "semantic-help: everyday: no error line \"$line\"" >&2; exit 1; }
done
expect everyday 'help: `Point` has no method `lenght`; did you mean `length`?'
expect everyday 'help: `Point` has no field `lenght`; did you mean `length`?'
expect everyday 'help: `area` takes `int` there, and this argument is `string`; to read a number from text: `value.parseInt()` (abla/integer), `null` when the text isn'"'"'t one'
expect everyday 'help: `d` is declared `int`, and the value is `string`; to read a number from text: `value.parseInt()` (abla/integer), `null` when the text isn'"'"'t one'
expect everyday 'help: no function or class named `aera` is visible here; did you mean `area`?'
expect everyday 'help: nothing named `widht` is visible here; did you mean `width`?'
expect everyday 'help: the call gives `area` another number of arguments than it declares (a parameter with a default may be left out)'
expect everyday 'help: an argument of `Point(...)` has a type its constructor parameter doesn'"'"'t take'
expect everyday 'help: an array literal'"'"'s elements all have the array'"'"'s element type, and one of these doesn'"'"'t'
expect everyday 'help: `n` is declared `string`, and the initializer is `int`; to make text of it: `"$value"`'
expect everyday 'help: `half` is declared to return `int`, and this value is `string`; to read a number from text: `value.parseInt()` (abla/integer), `null` when the text isn'"'"'t one'
absent everyday 'named `completelyUnrelatedName`'

build hidden
expect hidden 'help: no function or class named `helperTwp` is visible here; did you mean `helperTwo`?'
absent hidden 'did you mean `helperOne`'

# Five uses of println without abla/io: five errors, and on the command line one help line; an assignment of a string
# to an int names both types (from the nodes: its code names only the target).
build repeated
[[ $(grep -c '^error\[E_SEMANTIC\]: call.target:println$' "$output_directory/repeated.log") -eq 5 ]] ||
    { echo "semantic-help: repeated: not five errors" >&2; cat "$output_directory/repeated.log" >&2; exit 1; }
[[ $(grep -c '^help: `println` is declared in abla/io' "$output_directory/repeated.log") -eq 1 ]] ||
    { echo "semantic-help: repeated: the command line repeats the help line" >&2; cat "$output_directory/repeated.log" >&2; exit 1; }
expect repeated 'help: `count` is declared `int`, and the value is `string`; to read a number from text: `value.parseInt()` (abla/integer), `null` when the text isn'"'"'t one'
# The editor's analysis keeps the help on each of the five (a `help` field per diagnostic).
node -e '
const lines = [
  { schema: 1, id: 1, method: "initialize", params: { workspaceRoots: [process.argv[1]], clientName: "semantic-help", clientVersion: "1", analysisMode: "graph-v1" } },
  { schema: 1, id: 2, method: "analyze", params: { roots: [process.argv[2]] } },
  { schema: 1, id: 3, method: "shutdown", params: {} },
];
require("fs").writeFileSync(process.argv[3], lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
' "$project_root/tests/cases/semantic-help" "$project_root/tests/cases/semantic-help/repeated.ab" "$output_directory/analyze.jsonl"
"$compiler" analyze --stdio < "$output_directory/analyze.jsonl" > "$output_directory/analyze.out" 2> "$output_directory/analyze.err"
node -e '
const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").map(JSON.parse);
const all = [];
for (const line of lines) for (const document of (line.result && line.result.documents) || []) all.push(...(document.diagnostics || []));
const println = all.filter((d) => d.message === "error[E_SEMANTIC]: call.target:println");
const helped = println.filter((d) => Array.isArray(d.help) && d.help.some((h) => h.startsWith("`println` is declared in abla/io")));
const count = all.find((d) => d.message.startsWith("error[E_SEMANTIC]: assignment.type:count@"));
if (println.length !== 5 || helped.length !== 5) { console.error(`analysis: ${println.length} println errors, ${helped.length} with the help`); process.exit(1); }
if (!count || !(count.help || []).some((h) => h.startsWith("`count` is declared `int`, and the value is `string`"))) { console.error("analysis: the assignment has no typed help"); process.exit(1); }
' "$output_directory/analyze.out" || { echo "semantic-help: the editor's analysis lost a help line" >&2; exit 1; }
# The editor's analysis also gives each of those errors the edit that fixes it, as data (a "fixes" field next to "help"):
# a did-you-mean renames the name in its own range, a missing import adds the import line after the last import (or the
# header comments). Applied to the source, the edits give the corrected names and the one import line.
node -e '
const fs = require("fs");
const [root, dir, out] = process.argv.slice(1);
const files = ["everyday.ab", "repeated.ab"].map((f) => dir + "/" + f);
const lines = [{ schema: 1, id: 1, method: "initialize", params: { workspaceRoots: [root], clientName: "semantic-help", clientVersion: "1", analysisMode: "graph-v1" } }];
files.forEach((file, i) => lines.push({ schema: 1, id: 2 + i, method: "analyze", params: { roots: [file] } }));
lines.push({ schema: 1, id: 9, method: "shutdown", params: {} });
fs.writeFileSync(out, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
' "$project_root/tests/cases/semantic-help" "$project_root/tests/cases/semantic-help" "$output_directory/fixes.jsonl"
"$compiler" analyze --stdio < "$output_directory/fixes.jsonl" > "$output_directory/fixes.out" 2> "$output_directory/fixes.err"
node -e '
const fs = require("fs");
const dir = process.argv[2];
const answers = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").map(JSON.parse);
const fail = (message) => { console.error("fixes: " + message); process.exit(1); };
const documentOf = (id, file) => {
  const answer = answers.find((a) => a.id === id);
  const document = ((answer && answer.result && answer.result.documents) || []).find((d) => d.uri.endsWith("/" + file));
  if (!document) fail("no document " + file);
  return document;
};
const apply = (text, edits) => {
  const bytes = Buffer.from(text);
  let out = Buffer.alloc(0), at = 0;
  for (const e of edits.slice().sort((a, b) => a.range.start - b.range.start)) {
    out = Buffer.concat([out, bytes.subarray(at, e.range.start), Buffer.from(e.newText)]);
    at = e.range.end;
  }
  return Buffer.concat([out, bytes.subarray(at)]).toString();
};
const everyday = documentOf(2, "everyday.ab");
const source = fs.readFileSync(dir + "/everyday.ab", "utf8");
const bytes = Buffer.from(source);
const renames = [];
for (const d of everyday.diagnostics) for (const fix of d.fixes || []) {
  if (fix.kind !== "replace" || fix.edits.length !== 1) fail("a rename is not one replace edit: " + JSON.stringify(fix));
  const e = fix.edits[0];
  renames.push(bytes.subarray(e.range.start, e.range.end).toString() + ">" + e.newText + " " + fix.title);
}
const q = String.fromCharCode(96);
for (const name of [["lenght", "length"], ["aera", "area"], ["widht", "width"]]) {
  const want = name[0] + ">" + name[1] + " Change to " + q + name[1] + q;
  if (!renames.includes(want)) fail("no fix \"" + want + "\" in " + JSON.stringify(renames));
}
if (everyday.diagnostics.some((d) => (d.fixes || []).length && !(d.help || []).length)) fail("a fix without help");
if (everyday.diagnostics.some((d) => d.message.includes("completelyUnrelatedName") && d.fixes)) fail("a far name has a fix");
const repeated = documentOf(3, "repeated.ab");
const text = fs.readFileSync(dir + "/repeated.ab", "utf8");
const imports = repeated.diagnostics.flatMap((d) => d.fixes || []).filter((f) => f.kind === "import");
if (imports.length !== 5) fail(imports.length + " import fixes on the five println errors");
for (const fix of imports) {
  if (fix.title !== "Add import \"abla/io\"" || fix.edits.length !== 1) fail("import fix " + JSON.stringify(fix));
  const fixed = apply(text, fix.edits);
  const header = text.slice(0, text.indexOf("fun main"));
  if (fixed !== header + "import \"abla/io\"\n" + text.slice(header.length)) fail("the import is not after the header comments:\n" + fixed);
}
' "$output_directory/fixes.out" "$project_root/tests/cases/semantic-help" || { echo "semantic-help: the editor's analysis lost a fix" >&2; exit 1; }
echo "semantic-help: 11 everyday errors have their help line; a far name and a name strict imports hide are not suggested; a repeated help line is printed once on the command line and kept on each error in the analysis; a did-you-mean and a missing import also come as edits (fixes)"
