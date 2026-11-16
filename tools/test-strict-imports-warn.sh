#!/usr/bin/env bash
# `--strict-imports=warn` (decision #66, step 1): the modules `--strict-imports` would make strict build flat, as
# before, and every diagnostic strict imports would give them is a warning instead, with the same text, place and
# help line: the names of modules they don't import (the front end's check), the extension functions, operators and
# overloads of such modules (sema's), and a name two imports pass on through `export import`. Each is printed once.
# A package that sets `visibility` is not affected.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cases="$project_root/tests/cases"
output_directory="$project_root/build/strict-imports-warn"
rm -rf "$output_directory"
mkdir -p "$output_directory"

export ABLA_MAX_MEMORY_MB=${ABLA_MAX_MEMORY_MB:-4096}

fail() { echo "strict-imports-warn: $1"; cat "$output_directory/warn.err"; exit 1; }

warned() { # $1 = source, $2 = output it must print (exit 42), then the texts its warnings must contain
    local source=$1 expected=$2; shift 2
    "$compiler" build "$source" -o "$output_directory/warned" --strict-imports=warn \
        > "$output_directory/warn.err" 2>&1 || fail "$source did not build"
    grep -qF 'error[' "$output_directory/warn.err" && fail "$source has an error"
    for text in "$@"; do
        grep -qF -- "$text" "$output_directory/warn.err" || fail "$source lacks '$text'"
    done
    set +e
    output=$("$output_directory/warned")
    status=$?
    set -e
    [[ $status == 42 && $output == "$expected" ]] ||
        { echo "strict-imports-warn: $source exited with $status and printed:"; echo "$output"; exit 1; }
}

# Names (the front end's check), each with its place and the import to add.
warned "$cases/strict-imports/flat/main.ab" "81 x/y" \
    'warning[E_NAME_NOT_IMPORTED]: `bThing` is declared in' 'help: add: import "./b.ab"' \
    'help: add: import "abla/fs"' '--> '"$cases"'/strict-imports/flat/main.ab:7:'
[[ $(grep -c '^warning\[E_NAME_NOT_IMPORTED\]: `bThing`' "$output_directory/warn.err") == 1 ]] ||
    fail "bThing is not warned about once"

# Extension functions, operators and overloads (sema's): the three uses strict imports rejects, once each, and the
# flat program's output (label("s") keeps the overload flat chooses).
warned "$cases/strict-members/main.ab" "6 4 string string" \
    'warning[E_NAME_NOT_IMPORTED]: `Point.doubled` is declared in' \
    'warning[E_NAME_NOT_IMPORTED]: `Point.plus` is declared in' \
    'warning[E_NAME_NOT_IMPORTED]: `describe` is declared in' \
    'help: add: import "./extras.ab"'
for name in Point.doubled Point.plus describe; do
    [[ $(grep -c "^warning\[E_NAME_NOT_IMPORTED\]: \`$name\`" "$output_directory/warn.err") == 1 ]] ||
        fail "$name is not warned about once"
done

# A name two imports pass on through `export import` (strict rejects the import; flat builds it).
warned "$cases/strict-members/passed-on/unused.ab" "" \
    'warning[E_IMPORT_UNQUALIFIED_AMBIGUOUS]: unqualified declaration `shared` is exposed by both'
if "$compiler" build "$cases/strict-members/passed-on/unused.ab" -o "$output_directory/invalid" --no-cache \
    --strict-imports > "$output_directory/warn.err" 2>&1; then fail "passed-on/unused.ab compiled strict"; fi
grep -qF 'error[E_IMPORT_UNQUALIFIED_AMBIGUOUS]' "$output_directory/warn.err" ||
    fail "passed-on/unused.ab lacks its strict error"

# A strict package's errors stay errors; a --flat-imports build without the option prints nothing.
if "$compiler" build "$cases/strict-imports/pkg/bad.ab" -o "$output_directory/invalid" --strict-imports=warn \
    > "$output_directory/warn.err" 2>&1; then fail "pkg/bad.ab compiled"; fi
grep -qF 'error[E_NAME_NOT_IMPORTED]' "$output_directory/warn.err" || fail "pkg/bad.ab lacks its error"
"$compiler" build "$cases/strict-imports/flat/main.ab" -o "$output_directory/flat" --no-cache --flat-imports \
    > "$output_directory/warn.err" 2>&1 || fail "flat/main.ab did not build"
grep -qF 'warning[' "$output_directory/warn.err" && fail "a flat build without the option warned"
echo "strict-imports-warn: names, members, overloads and export-import ambiguity as warnings; strict packages and plain flat builds unchanged"
