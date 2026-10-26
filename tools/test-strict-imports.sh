#!/usr/bin/env bash
# Strict imports: a package with `visibility = "imports"` sees its own
# declarations, its direct imports' and their `export import`s, and a name it
# reaches any other way is E_NAME_NOT_IMPORTED with the import to add;
# `--strict-imports` makes a manifest-less program strict; and a flat
# program's `--visibility-report`, applied by tools/fix-imports.ab, makes it
# build strict. The standard library is strict too.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/strict-imports"
output_directory="$project_root/build/strict-imports"
rm -rf "$output_directory"
mkdir -p "$output_directory"

export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}

runs() { # $1 = executable, $2 = the output it must print (exit 42)
    set +e
    output=$("$1")
    status=$?
    set -e
    [[ $status == 42 ]] || { echo "strict-imports: $1 exited with $status"; exit 1; }
    [[ $output == "$2" ]] || { echo "strict-imports: $1 printed:"; echo "$output"; exit 1; }
}

rejected() { # $1 = source, $2 = extra build flag or "", then the texts its diagnostics must contain
    local source=$1 flag=$2; shift 2
    if "$compiler" build "$source" -o "$output_directory/invalid" --no-cache $flag \
        > "$output_directory/rejected.err" 2>&1; then
        echo "strict-imports: $source compiled"; exit 1
    fi
    for text in "$@"; do
        grep -qF -- "$text" "$output_directory/rejected.err" ||
            { echo "strict-imports: $source lacks '$text'"; cat "$output_directory/rejected.err"; exit 1; }
    done
}

# A strict package: re-exported names, members and named arguments resolve.
"$compiler" build "$cases/pkg/main.ab" -o "$output_directory/pkg" --no-cache
runs "$output_directory/pkg" "4 18 8 5"
rejected "$cases/pkg/bad.ab" "" \
    'error[E_NAME_NOT_IMPORTED]: `utilHelp` is declared in' 'help: add: import "./util.ab"'

# A flat program builds as before, and is rejected with --strict-imports; a
# standard-library name is suggested by the import the program writes.
"$compiler" build "$cases/flat/main.ab" -o "$output_directory/flat" --no-cache
runs "$output_directory/flat" "81 x/y"
rejected "$cases/flat/main.ab" --strict-imports \
    '`bThing` is declared in' 'help: add: import "./b.ab"' 'help: add: import "abla/fs"'

# Report, apply, and build strict.
cp -R "$cases/flat" "$output_directory/fixed"
"$compiler" build "$output_directory/fixed/main.ab" -o "$output_directory/flat" --no-cache \
    --visibility-report "$output_directory/report.tsv"
grep -qF "	bThing	" "$output_directory/report.tsv" ||
    { echo "strict-imports: the report lacks bThing"; cat "$output_directory/report.tsv"; exit 1; }
"$compiler" run "$project_root/tools/fix-imports.ab" -- "$output_directory/report.tsv" \
    > "$output_directory/fix.out"
grep -qF "fix-imports: 1 module(s) changed" "$output_directory/fix.out" ||
    { echo "strict-imports: fix-imports printed:"; cat "$output_directory/fix.out"; exit 1; }
"$compiler" build "$output_directory/fixed/main.ab" -o "$output_directory/fixed-main" \
    --no-cache --strict-imports
runs "$output_directory/fixed-main" "81 x/y"
# The standard library is a strict package: its facades pass on what they
# front, and a library module that uses a name it doesn't import is rejected,
# with the library module to import (here in a copy of the sysroot).
"$compiler" build "$cases/facade.ab" -o "$output_directory/facade" --no-cache --strict-imports
runs "$output_directory/facade" "x/y true"
sysroot=${ABLA_SYSROOT:-$project_root}
library_root="$output_directory/sysroot"
mkdir -p "$library_root"
cp -R "$sysroot/stdlib" "$sysroot/runtime" "$library_root/"
mkdir -p "$library_root/stdlib/abla/strict-fixture"
cp "$cases/library-fixture.ab" "$library_root/stdlib/abla/strict-fixture/entry.ab"
# (With the compiler binary: a launcher would set its own sysroot.)
source "$project_root/tools/compiler-binary.sh"
(compiler=$(abla_compiler_binary "$compiler")
ABLA_SYSROOT="$library_root" rejected "$cases/library-user.ab" "" \
    'error[E_NAME_NOT_IMPORTED]: `Path` is declared in' 'help: add: import "abla/sys/linux/fs"')
# A program's value named like a type the library's annotations name.
"$compiler" build "$cases/value-named-like-type.ab" -o "$output_directory/value-named" --no-cache
runs "$output_directory/value-named" "5"
"$compiler" build "$cases/value-named-like-type.ab" -o "$output_directory/value-named-strict" \
    --no-cache --strict-imports
runs "$output_directory/value-named-strict" "5"
# A type inside generic arguments or a function type names a type too.
"$compiler" build "$cases/generic-types/main.ab" -o "$output_directory/generic-types" \
    --no-cache --strict-imports
runs "$output_directory/generic-types" "5 2 1 3"
# A library module's other file isn't API: a flat program's report names the
# entry module that reaches it, and a strict program is told it's internal.
"$compiler" build "$cases/internal.ab" -o "$output_directory/internal" --no-cache \
    --visibility-report "$output_directory/internal.tsv" > "$output_directory/internal.out" 2>&1 || true
grep -F "	OpenSSL_version_num	" "$output_directory/internal.tsv" | grep -qF 'import "abla/tls/hosted"' ||
    { echo "strict-imports: the internal name's report line:"; cat "$output_directory/internal.tsv"; exit 1; }
rejected "$cases/internal.ab" --strict-imports \
    '`OpenSSL_version_num` is internal to the standard library' \
    'help: a library module that offers it would be a change to the standard library to request'
echo "strict-imports: strict package, export import, --strict-imports, report + fix-imports, strict standard library, internal library files"
