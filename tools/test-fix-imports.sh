#!/usr/bin/env bash
# `ablac fix-imports` (src/fix_imports.ab) on copies of tests/cases/fix-imports:
#   app        imports only ./mid.ab and uses println (abla/io), jsonParse (abla/json) and helper (./lib.ab, which only
#              mid.ab imports): one run adds the three imports, exits 0, and the program then builds and runs; a
#              second run adds nothing;
#   --dry-run  lists the first round's additions and changes no file;
#   ambiguous  tlsAvailable (abla/tls/hosted and abla/tls/pure): no import, the name listed, exit 1;
#   outside    the program imports ../shared/util.ab, which uses println: a file outside the program's directory is
#              not changed, the name is listed, exit 1.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
work="$project_root/build/fix-imports"
rm -rf "$work"
mkdir -p "$work"
fail() { echo "fix-imports: $1" >&2; [[ -f ${2:-} ]] && cat "$2" >&2; exit 1; }
fresh() { rm -rf "$work/$1"; cp -r "$project_root/tests/cases/fix-imports/$1" "$work/$1"; }
run() { # name args...: runs fix-imports, output in <name>.log, status in $status
    local name=$1
    shift
    set +e
    "$compiler" fix-imports "$@" > "$work/$name.log" 2>&1
    status=$?
    set -e
}

fresh app
run app "$work/app/main.ab"
[[ $status -eq 0 ]] || fail "app: exit $status, expected 0" "$work/app.log"
for line in 'import "./lib.ab"' 'import "abla/json"' 'import "abla/io"'; do
    grep -qxF "$line" "$work/app/main.ab" || fail "app: main.ab has no line $line" "$work/app.log"
done
grep -qxF 'fix-imports: added 3 import(s) in 1 file(s); 0 name(s) left unresolved' "$work/app.log" ||
    fail "app: the last line doesn't count 3 imports in 1 file" "$work/app.log"
"$compiler" build "$work/app/main.ab" -o "$work/app/program" --fast > "$work/app-build.log" 2>&1 ||
    fail "app: the fixed program does not build" "$work/app-build.log"
[[ $("$work/app/program") == "fixed 41" ]] || fail "app: the fixed program printed something else"
cp "$work/app/main.ab" "$work/app-after-first.ab"
run app-again "$work/app/main.ab"
[[ $status -eq 0 ]] || fail "app, second run: exit $status" "$work/app-again.log"
cmp -s "$work/app/main.ab" "$work/app-after-first.ab" || fail "app: a second run changed main.ab" "$work/app-again.log"
grep -qxF 'fix-imports: added 0 import(s) in 0 file(s); 0 name(s) left unresolved' "$work/app-again.log" ||
    fail "app: a second run counted something" "$work/app-again.log"

fresh app
run dry --dry-run "$work/app/main.ab"
grep -q 'would add import "./lib.ab"' "$work/dry.log" || fail "--dry-run: the missing import is not listed" "$work/dry.log"
diff -r "$project_root/tests/cases/fix-imports/app" "$work/app" > /dev/null || fail "--dry-run changed a file" "$work/dry.log"

fresh ambiguous
run ambiguous "$work/ambiguous/main.ab"
[[ $status -eq 1 ]] || fail "ambiguous: exit $status, expected 1" "$work/ambiguous.log"
grep -q '`tlsAvailable` declared in several standard modules (abla/tls/hosted,abla/tls/pure)' "$work/ambiguous.log" ||
    fail "ambiguous: tlsAvailable is not listed" "$work/ambiguous.log"
grep -q '^import' "$work/ambiguous/main.ab" && fail "ambiguous: an import was added" "$work/ambiguous.log"

fresh outside
run outside "$work/outside/app/main.ab"
[[ $status -eq 1 ]] || fail "outside: exit $status, expected 1" "$work/outside.log"
diff -r "$project_root/tests/cases/fix-imports/outside/shared" "$work/outside/shared" > /dev/null ||
    fail "outside: a file outside the program's directory was changed" "$work/outside.log"
grep -q 'shared/util.ab: `println` in a file outside the project' "$work/outside.log" ||
    fail "outside: the name in the outside file is not listed" "$work/outside.log"
echo "fix-imports: a program missing project and standard imports builds after one run; reruns, --dry-run, an ambiguous name and a file outside the project change nothing"
