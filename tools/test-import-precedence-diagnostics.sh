#!/usr/bin/env bash
# A missing imported file is an error at its import; `x & 1 == 0` (bitwise binds
# looser than comparison) gets a hint to parenthesize.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/import-precedence-diagnostics"
mkdir -p "$output_directory"

expect() { # file text…
    local file=$1; shift
    set +e
    diagnostics=$("$compiler" build "$project_root/tests/cases/modules/$file.ab" \
        -o "$output_directory/$file" 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 ]] || { echo "$file: built"; exit 1; }
    for text in "$@"; do
        [[ $diagnostics == *"$text"* ]] || { echo "$file: missing '$text'"; echo "$diagnostics"; exit 1; }
    done
}

expect import-missing "E_IMPORT_NOT_FOUND" "missing/file.ab" "help: check the path and spelling; a relative import starts from the directory of the importing file"
expect invalid-import-unquoted "E_IMPORT_PATH_UNQUOTED" 'help: write `import "abla/io"`'
expect bitwise-comparison-precedence "bitwise.type" "parenthesize the bitwise part"
echo "import and precedence diagnostics: missing import, & vs == hint"
