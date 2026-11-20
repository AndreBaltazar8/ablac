#!/usr/bin/env bash
# W_UNUSED_IMPORT (module.ab: bootstrapUnusedImportWarnings), behind --warn-unused-imports: an import nothing in the
# importing file uses gets a warning, an import used only through an extension method, a re-exported class or a
# `$json` subparser doesn't, nor one of a module with an @export function; a package's entry gets the
# `export import` line instead, and a module that runs compile code keeps its imports. `ablac fix-imports --prune`
# removes the warned imports, leaves the entry's, keeps the last import of a file with a #compilerGrant, and the
# pruned programs still build.
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
# Off without the flag.
(cd "$work" && "$compiler" build main.ab -o program --fast) > "$work/plain.log" 2>&1 || fail "plain build failed" "$work/plain.log"
! grep -q W_UNUSED_IMPORT "$work/plain.log" || fail "a warning without --warn-unused-imports" "$work/plain.log"
# A package's entry: the export-import line.
(cd "$work/pkg" && "$compiler" build app.ab -o program --fast --warn-unused-imports) > "$work/pkg.log" 2>&1 ||
    fail "pkg/app.ab didn't build" "$work/pkg.log"
grep -qxF 'warning[W_UNUSED_IMPORT]: lib.ab: `import "abla/json"` is neither used here nor passed on: `export import` it if the package means to offer it (W_UNUSED_IMPORT entry)' "$work/pkg.log" ||
    fail "no entry warning for pkg/lib.ab" "$work/pkg.log"


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
! grep -qxF 'import "abla/json"' "$work/grant/main.ab" || fail "grant/main.ab still imports abla/json" "$work/grant/main.ab"
grep -qxF 'import "./value.ab"' "$work/grant/main.ab" || fail "the prune removed the last import of a #compilerGrant file" "$work/grant/main.ab"
grep -qF 'kept: the last import of a file with a #compilerGrant' "$work/grant-prune.log" || fail "the kept import isn't listed" "$work/grant-prune.log"
echo "unused-imports: 2 warnings in main.ab (none for uses through an extension, a re-exported class, a subparser or an @export module), the entry's export-import line; the prune removed 2, left the entry's, kept the grant file's last"
