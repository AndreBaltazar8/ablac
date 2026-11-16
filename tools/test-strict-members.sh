#!/usr/bin/env bash
# Strict imports past plain names (decision #64's gaps): a strict module sees only the extension functions and
# extension operators of the modules it sees, and only their overloads; an overload it doesn't see is not a
# candidate, and when only such a one fits, E_NAME_NOT_IMPORTED names its module. `--visibility-report` lists those
# uses of a flat program as `member` and `overload` lines, which tools/fix-imports.ab applies like the others. A name
# two imports pass on from different modules through `export import` is E_IMPORT_UNQUALIFIED_AMBIGUOUS. An extension
# declared in its receiver type's own module is one of the type's methods, seen wherever the type is.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases/strict-members"
output_directory="$project_root/build/strict-members"
rm -rf "$output_directory"
mkdir -p "$output_directory"

runs() { # $1 = executable, $2 = the output it must print (exit 42)
    set +e
    output=$("$1")
    status=$?
    set -e
    [[ $status == 42 && $output == "$2" ]] ||
        { echo "strict-members: $1 exited with $status and printed:"; echo "$output"; exit 1; }
}

rejected() { # $1 = source, $2 = extra build flag or "", then the texts its diagnostics must contain
    local source=$1 flag=$2; shift 2
    if "$compiler" build "$source" -o "$output_directory/invalid" --no-cache $flag \
        > "$output_directory/rejected.err" 2>&1; then
        echo "strict-members: $source compiled"; exit 1
    fi
    for text in "$@"; do
        grep -qF -- "$text" "$output_directory/rejected.err" ||
            { echo "strict-members: $source lacks '$text'"; cat "$output_directory/rejected.err"; exit 1; }
    done
}

# Flat, as before.
"$compiler" build "$cases/main.ab" -o "$output_directory/flat" --no-cache --flat-imports
runs "$output_directory/flat" "6 4 string string"

# Strict: the extension, the operator and the only fitting overload name extras.ab, and the help imports it.
rejected "$cases/main.ab" --strict-imports \
    'error[E_NAME_NOT_IMPORTED]: `Point.doubled` is declared in' \
    'error[E_NAME_NOT_IMPORTED]: `Point.plus` is declared in' \
    'error[E_NAME_NOT_IMPORTED]: `describe` is declared in' \
    'help: add: import "./extras.ab"'
[[ $(grep -c 'E_NAME_NOT_IMPORTED' "$output_directory/rejected.err") == 3 ]] ||
    { echo "strict-members: not three errors:"; cat "$output_directory/rejected.err"; exit 1; }
grep -F 'is declared in' "$output_directory/rejected.err" | grep -vF 'extras.ab' &&
    { echo "strict-members: an error names another module"; exit 1; }

# Strict, no `describe` seen: each call names the module whose overload it fits.
rejected "$cases/unseen.ab" --strict-imports
grep -F '`describe` is declared in' "$output_directory/rejected.err" > "$output_directory/unseen.lines" || true
[[ $(wc -l < "$output_directory/unseen.lines") == 2 && $(grep -c '/types.ab,' "$output_directory/unseen.lines") == 1 &&
   $(grep -c '/extras.ab,' "$output_directory/unseen.lines") == 1 ]] ||
    { echo "strict-members: unseen.ab's errors:"; cat "$output_directory/rejected.err"; exit 1; }

# Strict: the better overload of a module it doesn't see is no candidate.
"$compiler" build "$cases/sees.ab" -o "$output_directory/sees" --no-cache --strict-imports
runs "$output_directory/sees" "any"

# The report lists each use with its kind, and fix-imports makes the program build strict with flat's output.
cp -R "$cases" "$output_directory/fixed"
"$compiler" build "$output_directory/fixed/main.ab" -o "$output_directory/reported" --no-cache --flat-imports \
    --visibility-report "$output_directory/report.tsv"
for row in $'\tPoint.doubled\t' $'\tPoint.plus\t' $'\tdescribe\t' $'\tlabel\t'; do
    grep -F -- "$row" "$output_directory/report.tsv" | grep -F 'import "./extras.ab"' >/dev/null ||
        { echo "strict-members: the report lacks $row"; cat "$output_directory/report.tsv"; exit 1; }
done
[[ $(awk -F'\t' '$7 == "member"' "$output_directory/report.tsv" | wc -l) == 2 &&
   $(awk -F'\t' '$7 == "overload"' "$output_directory/report.tsv" | wc -l) == 2 ]] ||
    { echo "strict-members: the report's kinds:"; cat "$output_directory/report.tsv"; exit 1; }
"$compiler" run "$project_root/tools/fix-imports.ab" -- "$output_directory/report.tsv" > "$output_directory/fix.out"
# Every name is imported now; the overloads describe and label come from two unqualified imports, which is
# ambiguous (an alias decides it), as the fixer's own help says.
rejected "$output_directory/fixed/main.ab" --strict-imports \
    'unqualified declaration `describe` is exposed by both' 'unqualified declaration `label` is exposed by both'
grep -q E_NAME_NOT_IMPORTED "$output_directory/rejected.err" &&
    { echo "strict-members: a name is still not imported after fix-imports:"; cat "$output_directory/rejected.err"; exit 1; }
# Under an alias the overloads are named through it, and the module's extension and operator are still seen (a
# member call has no qualifier): strict, with flat's output.
sed -i -e 's|^import "./extras.ab"$|import "./extras.ab" as extras|' -e 's/\${describe(/\${extras.describe(/; s/\${label(/\${extras.label(/' \
    "$output_directory/fixed/main.ab"
"$compiler" build "$output_directory/fixed/main.ab" -o "$output_directory/fixed-main" --no-cache --strict-imports
runs "$output_directory/fixed-main" "6 4 string string"

# A name that carries its module's prefix was resolved where it was written: a call through an alias to an
# overloaded function (abla/math/v8's roundEven, which abla/math/fast declares too), and a parameter default
# calling an overload of the callee's module, copied into a caller that doesn't import it.
for program in module-siblings/aliased-intrinsic modules/overload-defaults; do
    "$compiler" build "$project_root/tests/cases/$program.ab" -o "$output_directory/qualified" --no-cache \
        --strict-imports > "$output_directory/qualified.err" 2>&1 ||
        { echo "strict-members: $program doesn't build strict:"; cat "$output_directory/qualified.err"; exit 1; }
    set +e
    "$output_directory/qualified"; qualified=$?
    set -e
    [[ $qualified == 42 ]] || { echo "strict-members: $program exited $qualified"; exit 1; }
done

# An extension in its receiver type's own module belongs to the type.
"$compiler" build "$cases/belongs.ab" -o "$output_directory/belongs" --no-cache --strict-imports
set +e
"$output_directory/belongs"; belongs=$?
set -e
[[ $belongs == 42 ]] || { echo "strict-members: belongs exited $belongs"; exit 1; }

# Ambiguity through `export import`.
rejected "$cases/passed-on/main.ab" --strict-imports \
    'error[E_IMPORT_UNQUALIFIED_AMBIGUOUS]: unqualified declaration `shared` is exposed by both' 'passed-on/x.ab' \
    'passed-on/y.ab'
rejected "$cases/passed-on/facade.ab" --strict-imports \
    'error[E_IMPORT_UNQUALIFIED_AMBIGUOUS]: unqualified declaration `shared` is exposed by both'
"$compiler" build "$cases/passed-on/own.ab" -o "$output_directory/own" --no-cache --strict-imports
"$compiler" build "$cases/passed-on/same.ab" -o "$output_directory/same" --no-cache --strict-imports
set +e
"$output_directory/own"; own=$?
"$output_directory/same"; same=$?
set -e
[[ $own == 42 && $same == 42 ]] || { echo "strict-members: own exited $own, same $same"; exit 1; }
echo "strict-members: extensions, operators and overloads of unseen modules (errors, report kinds, fix-imports), overload choice among those seen, ambiguity through export import"
