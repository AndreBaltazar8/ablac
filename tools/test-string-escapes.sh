#!/usr/bin/env bash
# String escapes: \0 is NUL, \uXXXX and \u{H…} are UTF-8, and an unknown,
# short or surrogate escape is E_PARSE_INVALID_ESCAPE at the backslash.
set -euo pipefail

compiler=${1:-build/ablac.bin}
project_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
output_directory="$project_root/build/string-escapes"
mkdir -p "$output_directory"
cases="$project_root/tests/cases/modules"

"$compiler" build "$cases/string-escapes.ab" -o "$output_directory/string-escapes" --no-cache >/dev/null
actual=$("$output_directory/string-escapes")
expected=$'0 124 8 124 65 124 255\n1 65 195 169 226 130 172\n65 195 169 240 159 152 128 244 143 191 191\n"\'\\$ \n\t|'
[[ $actual == "$expected" ]] || { echo "decoded escapes differ:"; echo "$actual"; exit 1; }

expect() { # file text…
    local file=$1; shift
    set +e
    diagnostics=$("$compiler" build "$cases/$file.ab" \
        -o "$output_directory/$file" --no-cache 2>&1)
    status=$?
    set -e
    [[ $status -ne 0 ]] || { echo "$file: built"; exit 1; }
    for text in "$@"; do
        [[ $diagnostics == *"$text"* ]] || { echo "$file: missing '$text'"; echo "$diagnostics"; exit 1; }
    done
}

expect invalid-escape-unknown "E_PARSE_INVALID_ESCAPE" 'unknown escape `\q`' "invalid-escape-unknown.ab:26:28"
expect invalid-escape-surrogate "E_PARSE_INVALID_ESCAPE" "invalid Unicode escape"
expect invalid-escape-short "invalid Unicode escape"
expect invalid-escape-range "invalid Unicode escape"
echo "string escapes: \\0, \\x, \\u, \\u{…} decode; unknown/short/surrogate/out-of-range rejected"
