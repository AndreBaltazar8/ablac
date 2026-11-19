#!/usr/bin/env bash
# A `#` expression whose code needs a compile capability its module hasn't granted says what to add (sema.ab:
# bootstrapCompileGrantHelp, compileEffectPathShown), under the unchanged compile.effect-denied line: the module's
# `#compilerGrant("<capability>")`, and when the governing abla.toml doesn't authorize it, that file's
# `compileCapabilities` with what it lists plus the capability (or, with no manifest, the one line to write beside the
# entry); the path stops at the first standard-library function (`home` → `processEnvironment`, inside
# abla/process/environment). A misspelled capability in `#compilerGrant` gets the one close name.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
work="$project_root/build/ct-grant-help"
rm -rf "$work"
mkdir -p "$work"
cp -r "$project_root/tests/cases/ct-grant-help/." "$work/"

check() { # case expected-help-line
    local log="$work/$1.log"
    if (cd "$work/$1" && "$compiler" build main.ab -o program --fast) > "$log" 2>&1; then
        echo "ct-grant-help: $1 built; it lacks a grant" >&2
        exit 1
    fi
    grep -qxF "$2" "$log" || { echo "ct-grant-help: $1: no line \"$2\"" >&2; cat "$log" >&2; exit 1; }
}

check nomanifest 'help: the `#` expression reaches `load` → `Path.readText`, which needs `filesystem.read`: add `#compilerGrant("filesystem.read")` to main.ab; and authorize it in an abla.toml beside the entry: `compileCapabilities = ["filesystem.read"]`'
grep -qF 'error[E_SEMANTIC]: compile.effect-denied:filesystem.read:load->Path.readText' "$work/nomanifest.log" ||
    { echo "ct-grant-help: the error line changed" >&2; exit 1; }
check merged 'help: the `#` expression reaches `home` → `processEnvironment` (inside abla/process/environment), which needs `environment`: add `#compilerGrant("environment")` to main.ab; and authorize it in ./abla.toml: `compileCapabilities = ["clock", "environment"]`'
check authorized 'help: the `#` expression reaches `home` → `processEnvironment` (inside abla/process/environment), which needs `environment`: add `#compilerGrant("environment")` to main.ab'
check misspelled 'help: `filesytem.read` isn'"'"'t a compile capability; did you mean `filesystem.read`?'
echo "ct-grant-help: a missing grant names the grant line and the merged compileCapabilities, the path stops at the standard library, and a misspelled capability is corrected"
