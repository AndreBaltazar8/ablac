#!/usr/bin/env bash
# Two modules that declare the same names and neither imports the other (abla/tls/hosted and abla/tls/pure) coexist in one
# program: each module's names mean the declarations its own imports reach, however far (#830). Before, the program-wide
# names met as `symbol.duplicate:Conn` and a transitive constructor call matched the wrong class (`constructor.arity:Conn`).
# The compile-time evaluator resolves them the same way, and an aliased module's intrinsic runs under `#` (it was refused as
# trusted.native: the effect check read the prefixed name). A module that imports both unqualified is still
# E_IMPORT_UNQUALIFIED_AMBIGUOUS.
set -euo pipefail
project_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
compiler=${1:-$project_root/build/ablac}
case $compiler in /*) ;; *) compiler=$project_root/$compiler ;; esac
cases=$project_root/tests/cases/module-siblings
output_directory=$project_root/build/module-siblings
rm -rf "$output_directory"
mkdir -p "$output_directory"

for mode in release fast; do
    # Flat: what this checks is how far a flat module's names reach (deep.ab sees pure.ab through user.ab alone);
    # strict imports, the default, would reject that use as E_NAME_NOT_IMPORTED.
    flags=(--no-cache --flat-imports)
    [[ $mode == fast ]] && flags+=(--fast)
    if ! "$compiler" build "$cases/main.ab" -o "$output_directory/$mode" "${flags[@]}" > "$output_directory/$mode.log" 2>&1; then
        cat "$output_directory/$mode.log" >&2
        echo "module siblings: main.ab does not build ($mode)" >&2
        exit 1
    fi
    set +e
    "$output_directory/$mode"
    status=$?
    set -e
    [[ $status == 42 ]] || { echo "module siblings: main.ab exited $status ($mode)" >&2; exit 1; }
done

"$compiler" build "$cases/aliased-intrinsic.ab" -o "$output_directory/aliased-intrinsic" --no-cache \
    > "$output_directory/aliased-intrinsic.log" 2>&1 ||
    { cat "$output_directory/aliased-intrinsic.log" >&2; echo "module siblings: aliased-intrinsic.ab does not build" >&2; exit 1; }
set +e
"$output_directory/aliased-intrinsic"
status=$?
set -e
[[ $status == 42 ]] || { echo "module siblings: aliased-intrinsic.ab exited $status" >&2; exit 1; }

if "$compiler" build "$cases/ambiguous/main.ab" -o "$output_directory/ambiguous" --no-cache \
    > "$output_directory/ambiguous.err" 2>&1; then
    echo "module siblings: ambiguous/main.ab compiled" >&2
    exit 1
fi
grep -qF 'error[E_IMPORT_UNQUALIFIED_AMBIGUOUS]: unqualified declaration `Conn`' "$output_directory/ambiguous.err" ||
    { cat "$output_directory/ambiguous.err" >&2; echo "module siblings: no ambiguity error" >&2; exit 1; }
echo "module siblings: same-named declarations of sibling modules resolve by module (release, --fast, #); aliased intrinsics under #; a direct double import is ambiguous"
