#!/usr/bin/env bash
# W_UNUSED_IMPORT (module.ab: bootstrapUnusedImportWarnings), on by default (off with --no-warn-unused-imports or
# ABLA_WARN_UNUSED_IMPORTS=0, and a cache hit prints what its entry kept): an import nothing in the importing file uses
# gets a warning, an import used only through an extension method, a re-exported class or a
# `$json` subparser (also through a module that passes the registering one on) or an interpolated float doesn't, nor
# one of a module with an @export function; a package's entry gets the `export import` line instead, and a module that
# runs compile code or defines syntax (a subparser) keeps its imports. Another project's module, a
# vendored package and a checkout linked in get none, nor does any module after a front end that stopped at an error.
# `ablac fix-imports --prune` removes the warned imports, leaves the entry's, keeps the abla/compiler import a
# #compilerGrant uses, refuses a build that fails before every use is known, reaches the project's other directories
# from a test file's root, and the pruned programs still build.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
work="$project_root/build/unused-imports"
rm -rf "${work:?}"
mkdir -p "$work"
cp -r "$project_root/tests/cases/unused-imports/." "$work/"
fail() { echo "unused-imports: $1" >&2; [ -n "${2:-}" ] && cat "$2" >&2; exit 1; }

# The warnings, exactly: two in main.ab.
(cd "$work" && "$compiler" build main.ab -o program --fast --warn-unused-imports) > "$work/warn.log" 2>&1 ||
    fail "main.ab didn't build" "$work/warn.log"
grep '^warning\[W_UNUSED_IMPORT\]' "$work/warn.log" > "$work/warnings.txt" || true
cat > "$work/expected.txt" <<'TXT'
warning[W_UNUSED_IMPORT]: main.ab: nothing `import "abla/json"` declares is used here
warning[W_UNUSED_IMPORT]: main.ab: nothing `import "./helper.ab"` declares is used here
TXT
diff "$work/expected.txt" "$work/warnings.txt" > "$work/warn.diff" || fail "main.ab's warnings differ" "$work/warn.diff"
# On by default (decision #86); off with --no-warn-unused-imports or ABLA_WARN_UNUSED_IMPORTS=0.
(cd "$work" && "$compiler" build main.ab -o program --fast --no-cache) > "$work/plain.log" 2>&1 ||
    fail "plain build failed" "$work/plain.log"
grep -q 'W_UNUSED_IMPORT.*"abla/json"' "$work/plain.log" || fail "no warning by default" "$work/plain.log"
(cd "$work" && "$compiler" build main.ab -o program --fast --no-cache --no-warn-unused-imports) > "$work/off.log" 2>&1 ||
    fail "--no-warn-unused-imports build failed" "$work/off.log"
! grep -q W_UNUSED_IMPORT "$work/off.log" || fail "a warning with --no-warn-unused-imports" "$work/off.log"
(cd "$work" && ABLA_WARN_UNUSED_IMPORTS=0 "$compiler" build main.ab -o program --fast --no-cache) > "$work/env-off.log" 2>&1 ||
    fail "ABLA_WARN_UNUSED_IMPORTS=0 build failed" "$work/env-off.log"
! grep -q W_UNUSED_IMPORT "$work/env-off.log" || fail "a warning with ABLA_WARN_UNUSED_IMPORTS=0" "$work/env-off.log"
# A cached rebuild skips the front end and prints the lines its entry kept; turned off, it prints none.
cache="$work/cache"
(cd "$work" && ABLA_CACHE_DIR="$cache" "$compiler" build main.ab -o program --fast) > "$work/cold.log" 2>&1 ||
    fail "cold cached build failed" "$work/cold.log"
marker=$(find "$cache" -name 'native-*.source' -print -quit 2>/dev/null)
[ -n "$marker" ] && [ -f "${marker%.source}.unused" ] || fail "the cache entry kept no warnings" "$work/cold.log"
before=$(stat -c %Y "$marker")
sleep 1
(cd "$work" && ABLA_CACHE_DIR="$cache" "$compiler" build main.ab -o program --fast) > "$work/warm.log" 2>&1 ||
    fail "warm cached build failed" "$work/warm.log"
[ "$(stat -c %Y "$marker")" = "$before" ] || fail "the second build was not a cache hit" "$work/warm.log"
grep '^warning\[W_UNUSED_IMPORT\]' "$work/warm.log" > "$work/warm-warnings.txt" || true
diff "$work/expected.txt" "$work/warm-warnings.txt" > "$work/warm.diff" || fail "a cache hit's warnings differ" "$work/warm.diff"
(cd "$work" && ABLA_CACHE_DIR="$cache" "$compiler" build main.ab -o program --fast --no-warn-unused-imports) > "$work/warm-off.log" 2>&1 ||
    fail "warm build without warnings failed" "$work/warm-off.log"
! grep -q W_UNUSED_IMPORT "$work/warm-off.log" || fail "a cache hit warned with --no-warn-unused-imports" "$work/warm-off.log"
# A package's entry: the export-import line.
(cd "$work/pkg" && "$compiler" build app.ab -o program --fast --warn-unused-imports) > "$work/pkg.log" 2>&1 ||
    fail "pkg/app.ab didn't build" "$work/pkg.log"
grep -qxF 'warning[W_UNUSED_IMPORT]: lib.ab: `import "abla/json"` is neither used here nor passed on: `export import` it if the package means to offer it (W_UNUSED_IMPORT entry)' "$work/pkg.log" ||
    fail "no entry warning for pkg/lib.ab" "$work/pkg.log"


# The editor's analysis (graph-v2 with initialize unusedImports) gives the same two as warnings: severity "warning", the
# "unnecessary" tag, and a fix that removes the import's line; without the option, or for a program with an error, none.
editor() { # directory entry option(true|false) out
    node -e '
const fs = require("fs");
const [dir, entry, option, out] = process.argv.slice(1);
const params = { workspaceRoots: [dir], clientName: "unused-imports", clientVersion: "1", analysisMode: "graph-v2" };
if (option === "true") params.unusedImports = true;
const lines = [{ schema: 1, id: 1, method: "initialize", params },
  { schema: 1, id: 2, method: "analyze", params: { roots: [dir + "/" + entry] } },
  { schema: 1, id: 3, method: "shutdown", params: {} }];
fs.writeFileSync(out, lines.map((l) => JSON.stringify(l)).join("\n") + "\n");
' "$1" "$2" "$3" "$work/editor.jsonl"
    "$compiler" analyze --stdio < "$work/editor.jsonl" > "$4" 2> "$work/editor.err" || fail "the editor service failed" "$work/editor.err"
}
editor "$work" main.ab true "$work/editor.out"
node -e '
const fs = require("fs");
const answers = fs.readFileSync(process.argv[1], "utf8").trim().split("\n").map(JSON.parse);
const fail = (message) => { console.error("editor: " + message); process.exit(1); };
const document = answers.find((a) => a.id === 2).result.documents.find((d) => d.uri.endsWith("/main.ab"));
const warned = document.diagnostics.filter((d) => d.code === "W_UNUSED_IMPORT");
if (warned.length !== 2 || document.diagnostics.length !== 2) fail("not exactly the two warnings: " + JSON.stringify(document.diagnostics));
const bytes = Buffer.from(document.text);
const removed = [];
for (const d of warned) {
  if (d.severity !== "warning" || JSON.stringify(d.tags) !== "[\"unnecessary\"]") fail("severity or tags: " + JSON.stringify(d));
  const fix = (d.fixes || [])[0];
  if (!fix || fix.title !== "Remove unused import" || fix.kind !== "remove" || fix.edits.length !== 1 || fix.edits[0].newText !== "") fail("fix: " + JSON.stringify(d.fixes));
  removed.push(bytes.subarray(fix.edits[0].range.start, fix.edits[0].range.end).toString());
}
const want = ["import \"abla/json\"\n", "import \"./helper.ab\"\n"];
if (JSON.stringify(removed.sort()) !== JSON.stringify(want.sort())) fail("the fixes remove " + JSON.stringify(removed));
' "$work/editor.out" || fail "the editor's unused-import warnings differ"
editor "$work" main.ab false "$work/editor-off.out"
[[ $(node -e 'const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").map(JSON.parse); let n = 0; for (const l of lines) for (const d of (l.result && l.result.documents) || []) n += d.diagnostics.filter((x) => x.code === "W_UNUSED_IMPORT").length; process.stdout.write(String(n));' "$work/editor-off.out") == 0 ]] || fail "the editor warned without the option" "$work/editor-off.out"
editor "$work/broken" main.ab true "$work/editor-broken.out"
[[ $(node -e 'const lines = require("fs").readFileSync(process.argv[1], "utf8").trim().split("\n").map(JSON.parse); let n = 0; for (const l of lines) for (const d of (l.result && l.result.documents) || []) n += d.diagnostics.filter((x) => x.code === "W_UNUSED_IMPORT").length; process.stdout.write(String(n));' "$work/editor-broken.out") == 0 ]] || fail "the editor warned after a front end that stopped at an error" "$work/editor-broken.out"

# A module that runs compile code keeps its imports.
(cd "$work/compiled" && "$compiler" build main.ab -o program --fast --warn-unused-imports) > "$work/compiled.log" 2>&1 ||
    fail "compiled/main.ab didn't build" "$work/compiled.log"
! grep -q W_UNUSED_IMPORT "$work/compiled.log" || fail "a warning in a module that runs compile code" "$work/compiled.log"

# A package's vendored copy (.abla/packages/, gitignored, so the case keeps it as abla-packages/) is the package's.
mkdir -p "$work/vendored/.abla"
mv "$work/vendored/abla-packages" "$work/vendored/.abla/packages"
(cd "$work/vendored" && "$compiler" build main.ab -o program --fast --warn-unused-imports) > "$work/vendored.log" 2>&1 ||
    fail "vendored/main.ab didn't build" "$work/vendored.log"
! grep -q W_UNUSED_IMPORT "$work/vendored.log" || fail "a warning in a vendored package" "$work/vendored.log"
(cd "$work/vendored" && "$compiler" fix-imports main.ab --prune) > "$work/vendored-prune.log" 2>&1 ||
    fail "vendored prune failed" "$work/vendored-prune.log"
grep -qxF 'import "abla/json"' "$work/vendored/.abla/packages/fake/entry.ab" ||
    fail "the prune changed a vendored package" "$work/vendored/.abla/packages/fake/entry.ab"

# Another project's module (../lib, outside app's abla.toml): not this build's to warn about, nor the prune's.
(cd "$work/outside/app" && "$compiler" build --project . -o program --fast --warn-unused-imports) > "$work/outside.log" 2>&1 ||
    fail "outside/app didn't build" "$work/outside.log"
! grep -q W_UNUSED_IMPORT "$work/outside.log" || fail "a warning outside the project" "$work/outside.log"
(cd "$work/outside/app" && "$compiler" fix-imports --project . --prune) > "$work/outside-prune.log" 2>&1 ||
    fail "outside prune failed" "$work/outside-prune.log"
grep -qxF 'import "abla/json"' "$work/outside/lib/lib.ab" || fail "the prune changed another project's module" "$work/outside/lib/lib.ab"
grep -qxF 'fix-imports: removed 0 unused import(s) in 0 file(s); 0 restored, 0 left' "$work/outside-prune.log" ||
    fail "the outside prune listed something" "$work/outside-prune.log"

# A build that stops in the front end (a missing import) knows only some uses: no warnings, and the prune refuses.
if (cd "$work/broken" && "$compiler" build main.ab -o program --fast --warn-unused-imports) > "$work/broken.log" 2>&1; then
    fail "broken/main.ab built" "$work/broken.log"
fi
grep -q 'E_IMPORT_NOT_FOUND' "$work/broken.log" || fail "broken/main.ab failed for another reason" "$work/broken.log"
! grep -q W_UNUSED_IMPORT "$work/broken.log" || fail "warnings from a front end that stopped" "$work/broken.log"
cp "$work/broken/main.ab" "$work/broken/main.ab.before"
if (cd "$work/broken" && "$compiler" fix-imports main.ab --prune) > "$work/broken-prune.log" 2>&1; then
    fail "the prune of a failing build succeeded" "$work/broken-prune.log"
fi
grep -qF 'error(s) before every use is known; fix those first, nothing pruned' "$work/broken-prune.log" ||
    fail "the prune didn't say why" "$work/broken-prune.log"
cmp -s "$work/broken/main.ab" "$work/broken/main.ab.before" || fail "the prune changed a failing build's file" "$work/broken/main.ab"

# Another checkout linked in (engine -> ../other): its path reads as this project's, but it isn't.
ln -s ../other "$work/linked/app/engine"
(cd "$work/linked/app" && "$compiler" build main.ab -o program --fast --warn-unused-imports) > "$work/linked.log" 2>&1 ||
    fail "linked/app didn't build" "$work/linked.log"
! grep -q W_UNUSED_IMPORT "$work/linked.log" || fail "a warning through a linked checkout" "$work/linked.log"
(cd "$work/linked/app" && "$compiler" fix-imports main.ab --prune) > "$work/linked-prune.log" 2>&1 ||
    fail "linked prune failed" "$work/linked-prune.log"
grep -qxF 'import "abla/json"' "$work/linked/other/lib.ab" || fail "the prune changed a linked checkout's file" "$work/linked/other/lib.ab"

# A library has no main: E_NO_MAIN comes after the front end, so its warnings stand and the prune runs.
if (cd "$work/library" && "$compiler" build lib.ab -o program --fast --warn-unused-imports) > "$work/library.log" 2>&1; then
    fail "library/lib.ab built without a main" "$work/library.log"
fi
grep -q 'E_NO_MAIN' "$work/library.log" || fail "library/lib.ab failed for another reason" "$work/library.log"
grep -qxF 'warning[W_UNUSED_IMPORT]: lib.ab: nothing `import "abla/json"` declares is used here' "$work/library.log" ||
    fail "no warning for a library without main" "$work/library.log"
(cd "$work/library" && "$compiler" fix-imports lib.ab --prune) > "$work/library-prune.log" 2>&1 ||
    fail "the library prune refused" "$work/library-prune.log"
! grep -qxF 'import "abla/json"' "$work/library/lib.ab" || fail "the library prune left abla/json" "$work/library/lib.ab"
grep -qxF 'import "abla/text"' "$work/library/lib.ab" || fail "the library prune removed abla/text" "$work/library/lib.ab"

# A root in another directory of the project (tests/lib_test.ab, abla.toml one up): the build warns in src/lib.ab, and
# the prune from that root removes it there; the project is the manifest's directory, not the root file's.
(cd "$work/nested" && "$compiler" build tests/lib_test.ab -o program --fast) > "$work/nested.log" 2>&1 ||
    fail "nested/tests/lib_test.ab doesn't build" "$work/nested.log"
grep -qxF 'warning[W_UNUSED_IMPORT]: src/lib.ab: nothing `import "abla/json"` declares is used here' "$work/nested.log" ||
    fail "no warning in nested/src/lib.ab" "$work/nested.log"
(cd "$work/nested" && "$compiler" fix-imports tests/lib_test.ab --prune) > "$work/nested-prune.log" 2>&1 ||
    fail "the nested prune failed" "$work/nested-prune.log"
grep -qxF 'fix-imports: removed 1 unused import(s) in 1 file(s); 0 restored, 0 left' "$work/nested-prune.log" ||
    fail "the nested prune didn't remove src/lib.ab's import" "$work/nested-prune.log"
! grep -qxF 'import "abla/json"' "$work/nested/src/lib.ab" || fail "the nested prune left abla/json" "$work/nested/src/lib.ab"
grep -qxF 'import "abla/text"' "$work/nested/src/lib.ab" || fail "the nested prune removed abla/text" "$work/nested/src/lib.ab"

# Extensions nothing calls: their receivers and declared types are uses (sema never checks those bodies).
(cd "$work/receiver" && "$compiler" build main.ab -o program --fast --warn-unused-imports) > "$work/receiver.log" 2>&1 ||
    fail "receiver/main.ab didn't build" "$work/receiver.log"
! grep -q W_UNUSED_IMPORT "$work/receiver.log" || fail "a warning for an import only an extension's declaration uses" "$work/receiver.log"
(cd "$work/receiver" && "$compiler" fix-imports main.ab --prune) > "$work/receiver-prune.log" 2>&1 ||
    fail "receiver prune failed" "$work/receiver-prune.log"
for kept in ./shape.ab ./box.ab ./pair.ab ./point.ab; do
    grep -qxF "import \"$kept\"" "$work/receiver/ext.ab" || fail "the prune removed $kept from ext.ab" "$work/receiver/ext.ab"
done

# A float interpolated ("$x" lowers to abla/float/text's f64Text) is a use of abla/float/text: no warning, and the
# prune keeps it.
(cd "$work/interpolated" && "$compiler" build main.ab -o program --fast) > "$work/interpolated.log" 2>&1 ||
    fail "interpolated/main.ab doesn't build" "$work/interpolated.log"
! grep -q 'W_UNUSED_IMPORT' "$work/interpolated.log" || fail "an interpolated float's import is called unused" "$work/interpolated.log"
(cd "$work/interpolated" && "$compiler" fix-imports main.ab --prune) > "$work/interpolated-prune.log" 2>&1 ||
    fail "the interpolated prune failed" "$work/interpolated-prune.log"
grep -qxF 'fix-imports: removed 0 unused import(s) in 0 file(s); 0 restored, 0 left' "$work/interpolated-prune.log" ||
    fail "the interpolated prune touched abla/float/text" "$work/interpolated-prune.log"

# Syntax: dsl.ab registers `$seven()`, whose generated call needs ./helper.ab, so a module defining syntax keeps its
# imports; view.ab writes `$seven()` through kit.ab (which passes dsl.ab on), a use of ./kit.ab; main.ab imports kit.ab
# and never writes it: the one warning.
(cd "$work/syntax" && "$compiler" build main.ab -o program --fast) > "$work/syntax.log" 2>&1 ||
    fail "syntax/main.ab doesn't build" "$work/syntax.log"
[[ $(grep -c 'W_UNUSED_IMPORT' "$work/syntax.log") == 1 ]] || fail "syntax: not exactly one warning" "$work/syntax.log"
grep -qxF 'warning[W_UNUSED_IMPORT]: main.ab: nothing `import "./kit.ab"` declares is used here' "$work/syntax.log" ||
    fail "syntax: main.ab's unused kit.ab isn't warned" "$work/syntax.log"

# A module with a runtime hook (`fun __abla...`) matters by being loaded.
(cd "$work/hook" && "$compiler" build main.ab -o program --fast --warn-unused-imports) > "$work/hook.log" 2>&1 ||
    fail "hook/main.ab didn't build" "$work/hook.log"
! grep -q W_UNUSED_IMPORT "$work/hook.log" || fail "a warning for an import of a runtime hook's module" "$work/hook.log"
# The prune.
(cd "$work" && "$compiler" fix-imports main.ab --prune) > "$work/prune.log" 2>&1 || fail "prune failed" "$work/prune.log"
grep -qxF 'fix-imports: removed 2 unused import(s) in 1 file(s); 0 restored, 0 left' "$work/prune.log" ||
    fail "main.ab's prune counts" "$work/prune.log"
! grep -qE '^import "(abla/json|\./helper\.ab)"$' "$work/main.ab" || fail "main.ab still has the unused imports" "$work/main.ab"
for kept in abla/io abla/text abla/fs ./sub.ab ./exported.ab; do
    grep -qxF "import \"$kept\"" "$work/main.ab" || fail "the prune removed $kept" "$work/main.ab"
done
grep -qxF 'import "abla/json"' "$work/sub.ab" || fail "the prune removed sub.ab's abla/json" "$work/sub.ab"
(cd "$work" && "$compiler" build main.ab -o program --fast --warn-unused-imports) > "$work/after.log" 2>&1 ||
    fail "pruned main.ab doesn't build" "$work/after.log"
! grep -q W_UNUSED_IMPORT "$work/after.log" || fail "warnings left after the prune" "$work/after.log"

(cd "$work/pkg" && "$compiler" fix-imports app.ab --prune) > "$work/pkg-prune.log" 2>&1 || fail "pkg prune failed" "$work/pkg-prune.log"
grep -qxF 'import "abla/json"' "$work/pkg/lib.ab" || fail "the prune removed the entry's import" "$work/pkg/lib.ab"
grep -qF 'lib.ab: `import "abla/json"` left' "$work/pkg-prune.log" || fail "the entry's import isn't listed" "$work/pkg-prune.log"

(cd "$work/grant" && "$compiler" fix-imports main.ab --prune) > "$work/grant-prune.log" 2>&1 || fail "grant prune failed" "$work/grant-prune.log"
! grep -qE '^import "(abla/json|\./value\.ab)"$' "$work/grant/main.ab" || fail "grant/main.ab still has its unused imports" "$work/grant/main.ab"
grep -qxF 'import "abla/compiler"' "$work/grant/main.ab" || fail "the prune removed the import the #compilerGrant needs" "$work/grant/main.ab"
(cd "$work/grant" && "$compiler" build main.ab -o program --fast) > "$work/grant-after.log" 2>&1 || fail "pruned grant/main.ab doesn't build" "$work/grant-after.log"
echo "unused-imports: 2 warnings in main.ab (and in the editor's analysis, with a fix each) (none for uses through an extension, a re-exported class, a subparser, an @export module, a module that runs compile code, another project's, a vendored or linked one, or after a front end that stopped); the entry's export-import line; the prune removed 2, left the entry's, kept the import a #compilerGrant needs, and refused a failing build"
