#!/usr/bin/env bash
# Strict imports: a package with `visibility = "imports"` sees its own
# declarations, its direct imports' and their `export import`s, and a name it
# reaches any other way is E_NAME_NOT_IMPORTED with the import to add;
# `--strict-imports` makes a manifest-less program strict; and a flat
# program's `--visibility-report`, applied by tools/fix-imports.ab, makes it
# build strict. The standard library is strict too.
set -euo pipefail

compiler=${1:-build/ablac.bin}
# Absolute: the `test` checks run from the output directory.
[[ $compiler == /* || $compiler != */* ]] || compiler="$PWD/$compiler"
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
    if "$compiler" build "$source" -o "$output_directory/invalid" $flag \
        > "$output_directory/rejected.err" 2>&1; then
        echo "strict-imports: $source compiled"; exit 1
    fi
    for text in "$@"; do
        grep -qF -- "$text" "$output_directory/rejected.err" ||
            { echo "strict-imports: $source lacks '$text'"; cat "$output_directory/rejected.err"; exit 1; }
    done
}

# A strict package: re-exported names, members and named arguments resolve.
"$compiler" build "$cases/pkg/main.ab" -o "$output_directory/pkg"
runs "$output_directory/pkg" "4 18 8 5"
rejected "$cases/pkg/bad.ab" "" \
    'error[E_NAME_NOT_IMPORTED]: `utilHelp` is declared in' 'help: add: import "./util.ab"'

# In a strict package, an extension call of a module it doesn't import is an error and a report line too, so the
# fixer adds the import (abla-soap's string.trim needed abla/text, and the report didn't say).
cp -R "$cases/member-report" "$output_directory/member-report"
if "$compiler" build "$output_directory/member-report/main.ab" -o "$output_directory/invalid" \
    --visibility-report "$output_directory/member-report.tsv" > "$output_directory/member-report.err" 2>&1; then
    echo "strict-imports: a strict package's unimported extension call compiled"; exit 1
fi
grep -qF '`string.shout` is declared in' "$output_directory/member-report.err" &&
    grep -F '	string.shout	' "$output_directory/member-report.tsv" | grep -F 'member' >/dev/null ||
    { echo "strict-imports: the strict package's member report:"; cat "$output_directory/member-report.err" \
        "$output_directory/member-report.tsv"; exit 1; }
"$compiler" run "$project_root/tools/fix-imports.ab" -- "$output_directory/member-report.tsv" \
    > "$output_directory/member-report.fix"
"$compiler" build "$output_directory/member-report/main.ab" -o "$output_directory/member-report-main"
runs "$output_directory/member-report-main" "a!"

# A subparser's text is the subparser's: a word there that names a declaration elsewhere (abla-mvc's
# `$mvcview <main>`, `main` the program's) is no use of it, strict or in the report; an expression the subparser
# parses from the source is code, checked as any other.
"$compiler" build "$cases/subparser/main.ab" -o "$output_directory/subparser" --strict-imports
runs "$output_directory/subparser" ""
rejected "$cases/subparser/bad-main.ab" --strict-imports '`markupValue` is declared in'
if grep -qE '`(main|shell)` is declared in' "$output_directory/rejected.err"; then
    echo "strict-imports: a subparser's text taken for names:"; cat "$output_directory/rejected.err"; exit 1
fi
"$compiler" build "$cases/subparser/bad-main.ab" -o "$output_directory/subparser-flat" --flat-imports \
    --visibility-report "$output_directory/subparser.tsv"
grep -qF "	markupValue	" "$output_directory/subparser.tsv" && ! grep -qE '	(main|shell)	' "$output_directory/subparser.tsv" ||
    { echo "strict-imports: the subparser report:"; cat "$output_directory/subparser.tsv"; exit 1; }

# A program written flat builds with --flat-imports, and is rejected by default and with --strict-imports; a
# standard-library name is suggested by the import the program writes. Strict only by default, its
# E_NAME_NOT_IMPORTED names the opt-out in a second help line; asked for, it doesn't (decision #66, step 3).
"$compiler" build "$cases/flat/main.ab" -o "$output_directory/flat" --flat-imports
runs "$output_directory/flat" "81 x/y"
rejected "$cases/flat/main.ab" "" \
    '`bThing` is declared in' 'help: add: import "./b.ab"' 'help: add: import "abla/fs"' \
    'help: imports are strict by default; to build this package flat while its imports are added: --flat-imports'
rejected "$cases/flat/main.ab" --strict-imports \
    '`bThing` is declared in' 'help: add: import "./b.ab"' 'help: add: import "abla/fs"'
"$compiler" build "$cases/flat/main.ab" -o "$output_directory/invalid" --strict-imports \
    > "$output_directory/asked.out" 2>&1 || true
if grep -qF 'imports are strict by default' "$output_directory/asked.out"; then
    echo "strict-imports: --strict-imports, asked for, still names the opt-out"; exit 1
fi
# `ablac test` and `ablac run` take the modes too. (The flat program exits 42: under `test` it builds and fails by
# its exit, and strict it fails to build.) A strict run doesn't take the object a flat run of the program cached.
(cd "$output_directory" &&
    "$compiler" test --flat-imports "$cases/flat/main.ab" > test-flat.out 2>&1 || true
    grep -qF '(exit 42)' test-flat.out ||
        { echo "strict-imports: test --flat-imports:"; cat test-flat.out; exit 1; }
    "$compiler" test "$cases/flat/main.ab" > test-strict.out 2>&1 || true
    grep -qF '(build)' test-strict.out && grep -qF '`bThing` is declared in' test-strict.out ||
        { echo "strict-imports: test, strict by default:"; cat test-strict.out; exit 1; })
set +e
run_output=$("$compiler" run --flat-imports --cache-dir "$output_directory/run-cache" "$cases/flat/main.ab")
run_status=$?
set -e
[[ $run_status == 42 && $run_output == "81 x/y" ]] ||
    { echo "strict-imports: run --flat-imports exited $run_status, printed: $run_output"; exit 1; }
if "$compiler" run --cache-dir "$output_directory/run-cache" "$cases/flat/main.ab" \
    > "$output_directory/run-strict.out" 2>&1; then
    echo "strict-imports: a strict run took the flat run's object"; exit 1
fi
grep -qF '`bThing` is declared in' "$output_directory/run-strict.out" ||
    { echo "strict-imports: run, strict by default:"; cat "$output_directory/run-strict.out"; exit 1; }

# Report, apply, and build strict.
cp -R "$cases/flat" "$output_directory/fixed"
"$compiler" build "$output_directory/fixed/main.ab" -o "$output_directory/flat" --flat-imports \
    --visibility-report "$output_directory/report.tsv"
grep -qF "	bThing	" "$output_directory/report.tsv" ||
    { echo "strict-imports: the report lacks bThing"; cat "$output_directory/report.tsv"; exit 1; }
"$compiler" run "$project_root/tools/fix-imports.ab" -- "$output_directory/report.tsv" \
    > "$output_directory/fix.out"
grep -qF "fix-imports: 1 module(s) changed" "$output_directory/fix.out" ||
    { echo "strict-imports: fix-imports printed:"; cat "$output_directory/fix.out"; exit 1; }
"$compiler" build "$output_directory/fixed/main.ab" -o "$output_directory/fixed-main" \
    --strict-imports
runs "$output_directory/fixed-main" "81 x/y"
# A module the file imports under an alias isn't imported again: a second, plain import of it is
# E_IMPORT_ALIAS_TARGET_DUPLICATE.
mkdir -p "$output_directory/aliased"
printf 'import "abla/io"\nimport "abla/math" as m\n\nfun main: int = 42\n' > "$output_directory/aliased/main.ab"
printf '%s\t4\t1\tmathAbs\tstdlib/abla/math/entry.ab\timport "abla/math"\n' "$output_directory/aliased/main.ab" \
    > "$output_directory/aliased/report.tsv"
"$compiler" run "$project_root/tools/fix-imports.ab" -- "$output_directory/aliased/report.tsv" \
    > "$output_directory/aliased.out"
grep -qF "fix-imports: 0 module(s) changed" "$output_directory/aliased.out" &&
    [[ $(grep -c '^import "abla/math"' "$output_directory/aliased/main.ab") -eq 1 ]] ||
    { echo "strict-imports: fix-imports imported an aliased module again:"; cat "$output_directory/aliased/main.ab"; exit 1; }
# A module several programs share, whose name each program declares itself (a hook): the joined reports name a
# different module for it in each, and importing them all would make it ambiguous; no import, and it is listed.
mkdir -p "$output_directory/hook"
printf 'fun shared(): int = hook()\n' > "$output_directory/hook/shared.ab"
printf '%s\t1\t21\thook\ta.ab\timport "./a.ab"\n%s\t1\t21\thook\tb.ab\timport "./b.ab"\n' \
    "$output_directory/hook/shared.ab" "$output_directory/hook/shared.ab" > "$output_directory/hook/report.tsv"
"$compiler" run "$project_root/tools/fix-imports.ab" -- "$output_directory/hook/report.tsv" \
    > "$output_directory/hook.out"
grep -qF "fix-imports: 0 module(s) changed" "$output_directory/hook.out" &&
    grep -qF '`hook` is declared differently by the programs that share this module' "$output_directory/hook.out" &&
    ! grep -q '^import' "$output_directory/hook/shared.ab" ||
    { echo "strict-imports: fix-imports imported a hook each program declares:"; cat "$output_directory/hook.out" "$output_directory/hook/shared.ab"; exit 1; }
# A name in a file of another (vendored) package that its entry doesn't pass on: no import into .abla/, which would
# bypass the package import; it is listed, naming the package whose entry should `export import` the file.
mkdir -p "$output_directory/vendored/src"
printf 'fun lib(): int = parseIt()\n' > "$output_directory/vendored/src/lib.ab"
printf '%s\t1\t18\tparseIt\t.abla/packages/abla-xml/source/src/parse.ab\timport "../.abla/packages/abla-xml/source/src/parse.ab"\n' \
    "$output_directory/vendored/src/lib.ab" > "$output_directory/vendored/report.tsv"
"$compiler" run "$project_root/tools/fix-imports.ab" -- "$output_directory/vendored/report.tsv" \
    > "$output_directory/vendored.out"
grep -qF "fix-imports: 0 module(s) changed" "$output_directory/vendored.out" &&
    grep -qF "which package abla-xml's entry doesn't pass on: not imported" "$output_directory/vendored.out" &&
    ! grep -q '^import' "$output_directory/vendored/src/lib.ab" ||
    { echo "strict-imports: fix-imports imported a vendored package's file:"; cat "$output_directory/vendored.out" "$output_directory/vendored/src/lib.ab"; exit 1; }
# The standard library is a strict package: its facades pass on what they
# front, and a library module that uses a name it doesn't import is rejected,
# with the library module to import (here in a copy of the sysroot).
"$compiler" build "$cases/facade.ab" -o "$output_directory/facade" --strict-imports
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
"$compiler" build "$cases/value-named-like-type.ab" -o "$output_directory/value-named" --flat-imports
runs "$output_directory/value-named" "5"
"$compiler" build "$cases/value-named-like-type.ab" -o "$output_directory/value-named-strict" \
    --strict-imports
runs "$output_directory/value-named-strict" "5"
# A name reached only through a strict library module's own import is
# suggested by the module that declares it, not by the one the program wrote.
rejected "$cases/through-library.ab" --strict-imports \
    '`utf8Encode` is declared in' 'help: add: import "abla/text"'
# Built by a path relative to another directory (`ablac build ../main.ab`
# from lib/): the package is still strict, and the import is spelled from
# the module that needs it.
(compiler=$(cd "$(dirname "$compiler")" && pwd)/$(basename "$compiler")
cd "$cases/nested/lib" && rejected ../main.ab "" \
    'error[E_NAME_NOT_IMPORTED]: `thing` is declared in' 'help: add: import "../shared/thing.ab"')
# A type inside generic arguments or a function type names a type too.
"$compiler" build "$cases/generic-types/main.ab" -o "$output_directory/generic-types" \
    --strict-imports
runs "$output_directory/generic-types" "5 2 1 3"
# A type parameter in scope wins over a flat program's class of the same name
# (and over a standard-library type name); a class that is no type parameter
# there still is E_NAME_NOT_IMPORTED.
"$compiler" build "$cases/type-parameters/main.ab" -o "$output_directory/type-parameters" --flat-imports
runs "$output_directory/type-parameters" "3 6 5 4 15 9
15"
rejected "$cases/type-parameters/bad-main.ab" "" \
    'error[E_NAME_NOT_IMPORTED]: `Other` is declared in'
# A library module's other file isn't API: a flat program's report names the
# entry module that reaches it, and a strict program is told it's internal.
"$compiler" build "$cases/internal.ab" -o "$output_directory/internal" --flat-imports \
    --visibility-report "$output_directory/internal.tsv" > "$output_directory/internal.out" 2>&1 || true
grep -F "	OpenSSL_version_num	" "$output_directory/internal.tsv" | grep -F 'import "abla/tls/hosted"' >/dev/null ||
    { echo "strict-imports: the internal name's report line:"; cat "$output_directory/internal.tsv"; exit 1; }
rejected "$cases/internal.ab" --strict-imports \
    '`OpenSSL_version_num` is internal to the standard library' \
    'help: the public module(s) for this: abla/tls/hosted, abla/tls/pure' \
    'help: a library module that offers it would be a change to the standard library to request'
# The pointer is data in each internal file's header (`// public: <modules>`): every non-entry library file has it, and
# every module it names is a library module (an entry.ab); `none` says nothing public offers the file.
internal_count=0
while IFS= read -r internal_file; do
    internal_count=$((internal_count + 1))
    line=$(grep -m1 '^// public:' "$internal_file" || true)
    [[ -n $line ]] || { echo "strict-imports: $internal_file has no '// public:' header"; exit 1; }
    modules=$(sed -e 's|^// public:||' -e 's|,| |g' <<<"$line")
    [[ -n ${modules//[[:space:]]/} ]] || { echo "strict-imports: $internal_file: empty '// public:' header"; exit 1; }
    for module in $modules; do
        [[ $module == none ]] && continue
        [[ -f "$project_root/stdlib/$module/entry.ab" ]] ||
            { echo "strict-imports: $internal_file names $module, which is not a standard-library module"; exit 1; }
    done
done < <(find "$project_root/stdlib" -name '*.ab' ! -name entry.ab | sort)
[[ $internal_count -gt 0 ]] || { echo "strict-imports: no internal library files found"; exit 1; }
echo "strict-imports: strict package, export import, --strict-imports, report + fix-imports, strict standard library, internal library files"
