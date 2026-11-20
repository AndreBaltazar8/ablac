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
