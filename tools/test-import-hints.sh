#!/usr/bin/env bash
# A call of a function or class the program does not import, or a method of a type it does not import, says which
# standard-library module declares it and the import to add (sema.ab, bootstrapStandardImportHelp): println, the first
# error of most new programs, used to get only `call.target:println`. A name the standard library re-exports is shown
# through the module that re-exports it (Path through abla/fs, which programs import, not abla/sys/linux/fs), and a
# name nothing declares gets no help line.
set -euo pipefail

compiler=${1:-build/ablac}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
case "$compiler" in /*) ;; */*) compiler="$project_root/$compiler" ;; esac
output_directory="$project_root/build/import-hints"
mkdir -p "$output_directory"
log="$output_directory/missing.log"

if "$compiler" build "$project_root/tests/cases/import-hints/missing.ab" -o "$output_directory/missing" --fast > "$log" 2>&1; then
    echo "import-hints: tests/cases/import-hints/missing.ab built, but it imports nothing it calls" >&2
    exit 1
fi
expect() {
    grep -qxF "$1" "$log" || { echo "import-hints: no line \"$1\"" >&2; cat "$log" >&2; exit 1; }
}
expect 'help: `println` is declared in abla/io; add `import "abla/io"`'
expect 'help: `jsonParse` is declared in abla/json; add `import "abla/json"`'
expect 'help: `sha256` is declared in abla/crypto; add `import "abla/crypto"`'
expect 'help: `Path` is declared in abla/fs; add `import "abla/fs"`'
expect 'help: `repeat` is declared in abla/text; add `import "abla/text"`'
if grep -q '`notDeclaredAnywhere`' "$log"; then
    echo "import-hints: a name nothing declares got a help line" >&2
    cat "$log" >&2
    exit 1
fi
grep -q 'call.target:notDeclaredAnywhere' "$log" || { echo "import-hints: the undeclared call was not reported" >&2; exit 1; }
echo "import-hints: println, jsonParse, sha256, Path (through abla/fs) and string.repeat name their import; an undeclared name gets none"
